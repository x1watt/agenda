import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/foundation.dart';

import 'secrets.dart';

/// LAN sync between the desktop and the phone. On the desktop this runs the
/// server that paired phones talk to; on the phone it pairs with the desktop and
/// syncs the agenda and personal folders.
class SyncService extends ChangeNotifier {
  SyncService({required this.settings, required this.onFilesChanged});

  final AgendaSettings settings;

  /// Called after files changed on this device because of a sync.
  final VoidCallback onFilesChanged;

  static bool get isServer => Platform.isLinux;

  String get deviceName => settings.deviceName ?? (Platform.isAndroid ? 'phone' : Platform.localHostname);

  Map<String, String> get roots => {SyncRoots.agenda: settings.agendaDir, SyncRoots.personal: settings.personalDir};

  // ---- desktop: server ---------------------------------------------------------------

  SyncServer? server;
  String? serverError;

  Future<void> startServer() async {
    if (!isServer || !settings.syncEnabled || server != null) return;
    try {
      final (cert, key) = await ensureCertificate(AgendaPaths.syncDir);
      final s = SyncServer(
        roots: roots,
        name: deviceName,
        certPath: cert,
        keyPath: key,
        devicesFile: '${AgendaPaths.syncDir}/devices.json',
        apiKey: () => Secrets.apiKey(settings),
        onChanged: (_, _) => onFilesChanged(),
        onPaired: (_) => notifyListeners(),
      );
      await s.start();
      server = s;
      serverError = null;
      _watchPairRequests();
    } on Object catch (e) {
      serverError = '$e';
    }
    notifyListeners();
  }

  StreamSubscription<FileSystemEvent>? _pairWatch;

  /// Pairing without clicking: creating `~/.cache/agenda/pair-request` opens pairing and
  /// writes the code to `pair-code` next to it (mode 600), for scripted setups.
  void _watchPairRequests() {
    final dir = Directory(AgendaPaths.cacheDir)..createSync(recursive: true);
    Future<void> check() async {
      final req = File('${dir.path}/pair-request');
      if (!await req.exists()) return;
      await req.delete();
      final code = startPairing();
      if (code == null) return;
      final out = File('${dir.path}/pair-code');
      await out.writeAsString(code);
      await Process.run('chmod', ['600', out.path]);
      Timer(const Duration(minutes: 5), () async {
        if (await out.exists()) await out.delete();
      });
    }

    _pairWatch = dir.watch().listen((e) {
      if (e.path.endsWith('/pair-request')) unawaited(check());
    });
    unawaited(check());
  }

  Future<void> stopServer() async {
    await _pairWatch?.cancel();
    _pairWatch = null;
    await server?.stop();
    server = null;
    notifyListeners();
  }

  Future<void> setServerEnabled(bool on) async {
    settings.syncEnabled = on;
    await settings.save();
    on ? await startServer() : await stopServer();
  }

  String? startPairing() {
    final code = server?.startPairing();
    notifyListeners();
    // Refresh the page when the code expires.
    Timer(const Duration(minutes: 5, seconds: 1), notifyListeners);
    return code;
  }

  Future<void> revoke(SyncDevice d) async {
    await server?.revoke(d.token);
    notifyListeners();
  }

  /// The desktop's LAN addresses, to show next to the pairing code.
  Future<List<String>> lanAddresses() async => [
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
      if (!i.name.startsWith('docker') && !i.name.startsWith('br-') && !i.name.startsWith('veth'))
        for (final a in i.addresses)
          if (!a.isLoopback) a.address,
  ];

  // ---- phone: client ------------------------------------------------------------------

  SyncPeer? peer;
  SyncReport? lastReport;
  DateTime? lastSuccess;
  bool syncing = false;
  String? status;
  Timer? _periodic;
  Timer? _soon;
  SyncClient? _client;

  String get _stateDir => '${AgendaPaths.configDir}/sync-client';
  File get _peerFile => File('$_stateDir/peer.json');

  Future<void> startClient() async {
    if (isServer) return;
    final f = _peerFile;
    if (await f.exists()) {
      try {
        peer = SyncPeer.fromJson((jsonDecode(await f.readAsString()) as Map).cast<String, Object?>());
      } on Object {
        peer = null;
      }
    }
    _periodic = Timer.periodic(const Duration(seconds: 60), (_) => syncNow());
    notifyListeners();
    unawaited(syncNow());
  }

  Future<List<FoundDesktop>> discover() => discoverDesktops();

  /// Pairs with the desktop at [host]; returns an error text or null on success.
  Future<String?> pair(String host, String code, {int port = defaultSyncPort}) async {
    try {
      final (p, apiKey) = await pairWithDesktop(host, port, code, deviceName);
      peer = p;
      _client = null;
      await _savePeer();
      if (apiKey != null && apiKey.isNotEmpty) await Secrets.setApiKey(settings, apiKey);
      notifyListeners();
      unawaited(syncNow());
      return null;
    } on SyncException catch (e) {
      return e.message;
    } on Object catch (e) {
      return 'Could not reach the desktop at $host: $e';
    }
  }

  Future<void> unpair() async {
    peer = null;
    _client = null;
    if (await _peerFile.exists()) await _peerFile.delete();
    notifyListeners();
  }

  Future<void> _savePeer() async {
    await Directory(_stateDir).create(recursive: true);
    await writeBytesAtomic(_peerFile.path, utf8.encode(jsonEncode(peer!.toJson())));
  }

  /// Sync a few seconds from now (after a local change), collapsing bursts.
  void syncSoon() {
    if (isServer || peer == null) return;
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 3), syncNow);
  }

  Future<void> syncNow() async {
    final p = peer;
    if (isServer || p == null || syncing) return;
    syncing = true;
    status = 'Syncing...';
    notifyListeners();
    try {
      final client = _client ??= SyncClient(peer: p, roots: roots, stateDir: _stateDir, deviceName: deviceName);
      var report = await client.sync();
      if (report.errors.any((e) => e.startsWith('desktop not reachable'))) {
        // The desktop may have a new address: look for it on the LAN.
        final found = await discoverDesktops();
        final same = found.where((d) => d.name == p.name).firstOrNull ?? (found.length == 1 ? found.first : null);
        if (same != null && same.host != p.host) {
          p.host = same.host;
          await _savePeer();
          report = await client.sync();
        }
      }
      lastReport = report;
      if (report.errors.isEmpty) {
        lastSuccess = report.at;
        // A key saved on the desktop after pairing reaches the phone here.
        if (await Secrets.apiKey(settings) == null) {
          final key = await client.fetchApiKey();
          if (key != null && key.isNotEmpty) await Secrets.setApiKey(settings, key);
        }
      }
      status = report.errors.isEmpty ? 'Synced ${_hm(report.at)}: $report' : report.errors.first;
      if (report.pulled + report.merged + report.deletedHere + report.conflicts.length > 0) onFilesChanged();
    } on Object catch (e) {
      status = 'Sync failed: $e';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  static String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _periodic?.cancel();
    _soon?.cancel();
    unawaited(server?.stop());
    super.dispose();
  }
}
