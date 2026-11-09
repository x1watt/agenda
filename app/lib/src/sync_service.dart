import 'dart:async';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/foundation.dart';

import 'identity/identity.dart';
import 'sync/rns_node.dart';

/// Sync between every device of the account (laptops and phones holding the same
/// nsec), over Reticulum: on the LAN and through the public hubs.
///
/// Every device answers the others' requests about its files ([SyncHost]). For
/// each pair of devices one of them drives the sync (the one with the smaller
/// device id) with a [SyncSession]; the other only pokes it after a local change.
/// Messages on the wire (LXMF, JSON):
///
///   req  {t, id, body}   a sync request (see core/lib/src/sync/sync_protocol.dart)
///   res  {t, id, body}   its reply
///   poke {t}             "I changed something, sync with me"
class SyncService extends ChangeNotifier {
  SyncService({required this.settings, required this.onFilesChanged, KeyStore? keys}) : keys = keys ?? SecureKeyStore(AgendaPaths.syncDir);

  final AgendaSettings settings;

  /// Called after files changed on this device because of a sync.
  final VoidCallback onFilesChanged;

  String get deviceName => settings.deviceName ?? (Platform.isAndroid ? 'phone' : Platform.localHostname);

  Map<String, String> get roots => {SyncRoots.agenda: settings.agendaDir, SyncRoots.personal: settings.personalDir};

  List<String> get hubs => settings.syncHubs ?? defaultHubs;

  /// This device's secrets (its Reticulum identity, a copy of the account key).
  final KeyStore keys;
  late final account = Account(accountsDir: settings.paths.accountsDir, keys: keys);
  late final host = SyncHost(roots: roots, onChanged: (_, _) => _changedByPeer());

  RnsNode? node;
  String? error;

  /// Per device: the last sync and its result.
  final reports = <String, SyncReport>{};
  final lastSuccess = <String, DateTime>{};
  final _syncing = <String>{};
  final _pending = <String, Completer<Map<String, Object?>>>{};
  var _nextId = 0;
  Timer? _periodic;
  Timer? _soon;
  Timer? _changed;

  Identity? get identity => account.identity;
  bool get running => node?.running ?? false;
  bool get syncing => _syncing.isNotEmpty;
  Iterable<DevicePeer> get devices => node?.peers.values ?? const [];

  /// The latest successful sync with any device.
  DateTime? get lastAnySuccess => lastSuccess.values.fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

  /// One line for menus and tooltips.
  String get status {
    if (!settings.syncEnabled) return 'Sync off';
    if (error != null) return 'Sync: $error';
    final n = node;
    if (n == null || !n.running) return 'Sync starting...';
    final hubsUp = n.connectedHubs.length;
    final last = lastAnySuccess;
    return [
      '${devices.length} other device${devices.length == 1 ? '' : 's'}',
      hubsUp == 0 ? (n.lanUp ? 'LAN only' : 'offline') : '$hubsUp hub${hubsUp == 1 ? '' : 's'}',
      if (syncing) 'syncing...' else if (last != null) 'synced ${_hm(last)}',
    ].join(', ');
  }

  // ---- lifecycle ---------------------------------------------------------------------

  Future<void> start() async {
    try {
      await account.load();
    } on Object catch (e) {
      error = 'account: $e';
      notifyListeners();
      return;
    }
    if (settings.syncEnabled) await _startNode();
  }

  Future<void> _startNode() async {
    if (node != null) return;
    final n = RnsNode(
      account: account.identity!,
      keys: keys,
      deviceName: deviceName,
      hubs: hubs,
      onMessage: _onMessage,
      onPeer: _onPeer,
    );
    n.addListener(notifyListeners);
    node = n;
    error = null;
    notifyListeners();
    try {
      await n.start();
    } on Object catch (e) {
      error = 'start failed: $e';
      n.log(error!);
    }
    _periodic = Timer.periodic(const Duration(minutes: 3), (_) => syncNow());
  }

  Future<void> stop() async {
    _periodic?.cancel();
    _soon?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(SyncException('sync stopped'));
    }
    _pending.clear();
    final n = node;
    node = null;
    n?.removeListener(notifyListeners);
    await n?.stop();
    notifyListeners();
  }

  Future<void> _restart() async {
    await stop();
    if (settings.syncEnabled) await _startNode();
  }

  Future<void> setEnabled(bool on) async {
    settings.syncEnabled = on;
    await settings.save();
    on ? await _startNode() : await stop();
  }

  Future<void> setHubs(List<String>? hubs) async {
    settings.syncHubs = hubs == null || hubs.isEmpty ? null : hubs;
    await settings.save();
    await _restart();
  }

  /// Installs the account of another device on this one; returns an error text or null.
  Future<String?> importAccount(String nsec) async {
    try {
      await account.import(nsec);
    } on FormatException {
      return 'That is not an nsec (it starts with nsec1).';
    }
    reports.clear();
    lastSuccess.clear();
    await _restart();
    return null;
  }

  // ---- messages -------------------------------------------------------------------------

  /// True when this device drives the sync with [peer]: exactly one of each pair does.
  bool _drives(String peer) => (node?.deviceId ?? '').compareTo(peer) < 0;

  void _onPeer(String peer) {
    if (!_drives(peer)) return;
    final last = lastSuccess[peer];
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) return;
    unawaited(syncWith(peer));
  }

  void _onMessage(String peer, Map<String, Object?> msg) {
    switch (msg['t']) {
      case 'req':
        unawaited(() async {
          final body = msg['body'];
          final reply = body is Map ? await host.handle(body.cast<String, Object?>()) : {'error': 'bad request'};
          await node?.send(peer, {'t': 'res', 'id': msg['id'], 'body': reply});
        }());
      case 'res':
        final c = _pending.remove('$peer/${msg['id']}');
        final body = msg['body'];
        if (c != null && !c.isCompleted) c.complete(body is Map ? body.cast<String, Object?>() : {'error': 'bad reply'});
      case 'poke':
        if (_drives(peer)) unawaited(syncWith(peer));
    }
  }

  /// One request to [peer]'s host and its reply.
  Future<Map<String, Object?>> _request(String peer, Map<String, Object?> req) async {
    final n = node;
    final name = n?.peers[peer]?.name ?? peer.substring(0, 8);
    if (n == null) throw SyncException('sync stopped');
    final id = '${_nextId++}';
    final c = _pending['$peer/$id'] = Completer<Map<String, Object?>>();
    if (!await n.send(peer, {'t': 'req', 'id': id, 'body': req})) {
      _pending.remove('$peer/$id');
      throw SyncException('$name not reachable');
    }
    try {
      return await c.future.timeout(const Duration(minutes: 3));
    } on TimeoutException {
      throw SyncException('$name did not answer');
    } finally {
      _pending.remove('$peer/$id');
    }
  }

  // ---- syncing --------------------------------------------------------------------------

  /// Syncs with [peer] now (this device drives).
  Future<void> syncWith(String peer) async {
    final n = node;
    final p = n?.peers[peer];
    if (n == null || p == null || !_syncing.add(peer)) return;
    notifyListeners();
    try {
      final session = SyncSession(
        transport: RequestTransport((req) => _request(peer, req)),
        roots: roots,
        stateDir: '${AgendaPaths.syncDir}/peers/$peer',
        deviceName: deviceName,
        peerName: p.name,
      );
      final r = await session.sync();
      reports[peer] = r;
      if (r.errors.isEmpty) lastSuccess[peer] = r.at;
      n.log('sync with ${p.name}: $r');
      if (r.changedHere) onFilesChanged();
    } on Object catch (e) {
      n.log('sync with ${p.name} failed: $e');
    } finally {
      _syncing.remove(peer);
      notifyListeners();
    }
  }

  /// Syncs with every device this one drives and pokes the others.
  Future<void> syncNow() async {
    final n = node;
    if (n == null) return;
    await n.tick();
    for (final peer in n.peers.keys.toList()) {
      if (_drives(peer)) {
        await syncWith(peer);
      } else {
        unawaited(n.send(peer, {'t': 'poke'}));
      }
    }
  }

  /// Sync a few seconds from now (after a local change), collapsing bursts.
  void syncSoon() {
    if (node == null) return;
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 5), syncNow);
  }

  /// A peer wrote files here: reload once its burst of writes is over.
  void _changedByPeer() {
    _changed?.cancel();
    _changed = Timer(const Duration(milliseconds: 500), onFilesChanged);
  }

  static String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _periodic?.cancel();
    _soon?.cancel();
    _changed?.cancel();
    unawaited(node?.stop());
    super.dispose();
  }
}
