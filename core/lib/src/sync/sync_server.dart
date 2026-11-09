/// The desktop side of the LAN sync: an HTTPS file service for paired phones and
/// a UDP responder so phones can find it. The phone drives every sync.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'manifest.dart';

const defaultSyncPort = 47600;
const defaultDiscoveryPort = 47601;
const discoveryQuery = 'AGENDA?';

/// A paired phone.
class SyncDevice {
  SyncDevice({required this.name, required this.token, required this.paired, this.lastSeen});
  final String name;
  final String token;
  final DateTime paired;
  DateTime? lastSeen;

  factory SyncDevice.fromJson(Map<String, Object?> j) => SyncDevice(
    name: '${j['name']}',
    token: '${j['token']}',
    paired: DateTime.tryParse('${j['paired']}') ?? DateTime.now(),
    lastSeen: DateTime.tryParse('${j['last_seen']}'),
  );

  Map<String, Object?> toJson() => {'name': name, 'token': token, 'paired': paired.toIso8601String(), 'last_seen': lastSeen?.toIso8601String()};
}

String _randomHex(int bytes) {
  final r = Random.secure();
  return [for (var i = 0; i < bytes; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

/// SHA-256 of a certificate's DER bytes, hex. Both sides pin on this.
String certFingerprint(List<int> der) => sha256.convert(der).toString();

/// DER bytes of the first certificate in a PEM file.
List<int> pemToDer(String pem) {
  final m = RegExp(r'-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----').firstMatch(pem);
  if (m == null) throw const FormatException('no certificate in PEM');
  return base64.decode(m.group(1)!.replaceAll(RegExp(r'\s'), ''));
}

/// The MAC that proves the pairing reply comes from the desktop showing [code].
String pairingMac(String code, String fingerprint, String token) =>
    Hmac(sha256, utf8.encode(code)).convert(utf8.encode('$fingerprint|$token')).toString();

/// Creates a self-signed certificate and key in [dir] (once) with openssl.
Future<(String cert, String key)> ensureCertificate(String dir) async {
  final cert = '$dir/cert.pem', key = '$dir/key.pem';
  if (await File(cert).exists() && await File(key).exists()) return (cert, key);
  await Directory(dir).create(recursive: true);
  final r = await Process.run('openssl', [
    'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', //
    '-keyout', key, '-out', cert, '-days', '3650', '-subj', '/CN=agenda-desktop',
  ]);
  if (r.exitCode != 0) throw ProcessException('openssl', const [], '${r.stderr}', r.exitCode);
  await Process.run('chmod', ['600', key]);
  return (cert, key);
}

/// Writes [bytes] to [path] atomically and sets its modification time.
Future<void> writeBytesAtomic(String path, List<int> bytes, {DateTime? mtime}) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
  await tmp.writeAsBytes(bytes, flush: true);
  if (mtime != null) await tmp.setLastModified(mtime);
  await tmp.rename(path);
}

/// Serves [roots] (sync root name -> directory) to paired devices.
class SyncServer {
  SyncServer({
    required this.roots,
    required this.name,
    required this.certPath,
    required this.keyPath,
    required this.devicesFile,
    this.port = defaultSyncPort,
    this.discoveryPort = defaultDiscoveryPort,
    this.apiKey,
    this.onChanged,
    this.onPaired,
  });

  final Map<String, String> roots;
  final String name;
  final String certPath;
  final String keyPath;
  final String devicesFile;
  final int port;
  final int discoveryPort;

  /// Handed to a phone during pairing, when set (the Anthropic API key).
  final Future<String?> Function()? apiKey;

  /// Called after a device wrote or deleted a file (root, path).
  final void Function(String root, String path)? onChanged;
  final void Function(SyncDevice)? onPaired;

  final devices = <SyncDevice>[];
  final _caches = <String, HashCache>{};
  HttpServer? _http;
  RawDatagramSocket? _udp;
  String? _code;
  DateTime? _codeExpires;
  late final String fingerprint = certFingerprint(pemToDer(File(certPath).readAsStringSync()));

  bool get running => _http != null;

  /// The port actually bound (useful when [port] is 0).
  int get boundPort => _http?.port ?? port;
  String? get pairingCode => _codeExpires != null && DateTime.now().isBefore(_codeExpires!) ? _code : null;

  /// Opens pairing for five minutes and returns the code to show.
  String startPairing() {
    _code = (Random.secure().nextInt(900000) + 100000).toString();
    _codeExpires = DateTime.now().add(const Duration(minutes: 5));
    return _code!;
  }

  void stopPairing() => _codeExpires = null;

  Future<void> start() async {
    await _loadDevices();
    final ctx = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);
    _http = await HttpServer.bindSecure(InternetAddress.anyIPv4, port, ctx);
    _http!.listen((req) => _handle(req).catchError((Object e) {
      try {
        req.response.statusCode = 500;
        req.response.write('$e');
        req.response.close();
      } on Object catch (_) {}
    }));
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort);
      _udp!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = _udp!.receive();
        if (d == null || utf8.decode(d.data, allowMalformed: true).trim() != discoveryQuery) return;
        _udp!.send(utf8.encode(jsonEncode({'agenda': 1, 'name': name, 'port': port})), d.address, d.port);
      });
    } on SocketException {
      // Discovery is a convenience; the phone also remembers the address.
    }
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _udp?.close();
    _http = null;
    _udp = null;
  }

  Future<void> _loadDevices() async {
    devices.clear();
    final f = File(devicesFile);
    if (!await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is Map && j['devices'] is List) {
        devices.addAll((j['devices'] as List).whereType<Map<String, Object?>>().map(SyncDevice.fromJson));
      }
    } on FormatException {
      // A broken file means no paired devices; pairing again rewrites it.
    }
  }

  Future<void> _saveDevices() async {
    await writeBytesAtomic(devicesFile, utf8.encode(const JsonEncoder.withIndent('  ').convert({'devices': [for (final d in devices) d.toJson()]})));
    await Process.run('chmod', ['600', devicesFile]);
  }

  Future<void> revoke(String token) async {
    devices.removeWhere((d) => d.token == token);
    await _saveDevices();
  }

  Future<void> _json(HttpResponse res, Object? body, {int status = 200}) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  /// Resolves `root` and `path` query parameters to a file inside a sync root, or null.
  String? _target(HttpRequest req) {
    final root = req.uri.queryParameters['root'] ?? '';
    final rel = req.uri.queryParameters['path'] ?? '';
    final dir = roots[root];
    if (dir == null || !SyncRoots.includes(root, rel)) return null;
    return '$dir/$rel';
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path == '/ping') return _json(res, {'name': name});
    if (path == '/pair' && req.method == 'POST') return _pair(req);

    final auth = req.headers.value('authorization') ?? '';
    final device = devices.where((d) => auth == 'Bearer ${d.token}').firstOrNull;
    if (device == null) return _json(res, {'error': 'not paired'}, status: 401);
    device.lastSeen = DateTime.now();

    if (path == '/apikey' && req.method == 'GET') return _json(res, {'api_key': await apiKey?.call()});

    if (path == '/manifest' && req.method == 'GET') {
      final root = req.uri.queryParameters['root'] ?? '';
      final dir = roots[root];
      if (dir == null) return _json(res, {'error': 'unknown root'}, status: 404);
      final files = await scanRoot(root, dir, cache: _caches.putIfAbsent(root, HashCache.new));
      return _json(res, {'root': root, 'files': {for (final e in files.entries) e.key: e.value.toJson()}});
    }

    final target = _target(req);
    if (target == null) return _json(res, {'error': 'path not synced'}, status: 400);
    final file = File(target);
    final exists = await file.exists();
    final current = exists ? hashBytes(await file.readAsBytes()) : 'none';

    switch (req.method) {
      case 'GET':
        if (!exists) return _json(res, {'error': 'not found'}, status: 404);
        res.headers.set('x-hash', current);
        res.headers.set('x-mtime', (await file.lastModified()).millisecondsSinceEpoch);
        res.headers.contentType = ContentType.binary;
        await res.addStream(file.openRead());
        await res.close();
      case 'PUT':
        final base = req.headers.value('x-base') ?? '';
        final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        if (base != current) return _json(res, {'error': 'changed', 'hash': current}, status: 409);
        final mtime = int.tryParse(req.headers.value('x-mtime') ?? '');
        await writeBytesAtomic(target, body, mtime: mtime == null ? null : DateTime.fromMillisecondsSinceEpoch(mtime));
        onChanged?.call(req.uri.queryParameters['root']!, req.uri.queryParameters['path']!);
        return _json(res, {'h': hashBytes(body)});
      case 'DELETE':
        final base = req.headers.value('x-base') ?? '';
        if (base != current) return _json(res, {'error': 'changed', 'hash': current}, status: 409);
        if (exists) await file.delete();
        onChanged?.call(req.uri.queryParameters['root']!, req.uri.queryParameters['path']!);
        return _json(res, {'ok': true});
    }
    return _json(res, {'error': 'method'}, status: 405);
  }

  Future<void> _pair(HttpRequest req) async {
    final body = jsonDecode(await utf8.decodeStream(req));
    final code = body is Map ? '${body['code']}' : '';
    final deviceName = body is Map ? '${body['name'] ?? 'phone'}' : 'phone';
    final open = pairingCode;
    if (open == null || code != open) {
      await Future<void>.delayed(const Duration(seconds: 1)); // slows down guessing
      return _json(req.response, {'error': 'wrong or expired code'}, status: 403);
    }
    stopPairing();
    final token = _randomHex(32);
    final device = SyncDevice(name: deviceName, token: token, paired: DateTime.now());
    devices.add(device);
    await _saveDevices();
    onPaired?.call(device);
    return _json(req.response, {
      'token': token,
      'fingerprint': fingerprint,
      'name': name,
      'mac': pairingMac(code, fingerprint, token),
      'api_key': await apiKey?.call(),
    });
  }
}
