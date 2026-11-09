/// The phone side of the LAN sync. It compares its files, the desktop's files and
/// the state of the last sync (the base), then pulls, pushes, deletes or merges.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../store.dart' show encodeJson, validateEventsJson, validateProjectJson, validateRecurringJson, validateTaskJson;
import 'json_merge.dart';
import 'manifest.dart';
import 'sync_server.dart';

/// Where the desktop is and how to prove we are paired with it.
class SyncPeer {
  SyncPeer({required this.host, required this.port, required this.token, required this.fingerprint, required this.name});
  String host;
  final int port;
  final String token;
  final String fingerprint;
  final String name;

  factory SyncPeer.fromJson(Map<String, Object?> j) => SyncPeer(
    host: '${j['host']}',
    port: (j['port'] as num?)?.toInt() ?? defaultSyncPort,
    token: '${j['token']}',
    fingerprint: '${j['fingerprint']}',
    name: '${j['name']}',
  );

  Map<String, Object?> toJson() => {'host': host, 'port': port, 'token': token, 'fingerprint': fingerprint, 'name': name};
}

/// What one sync did.
class SyncReport {
  int pulled = 0, pushed = 0, deletedHere = 0, deletedThere = 0, merged = 0;
  final conflicts = <String>[];
  final errors = <String>[];
  DateTime at = DateTime.now();

  int get changes => pulled + pushed + deletedHere + deletedThere + merged;

  @override
  String toString() => [
    if (pulled > 0) '$pulled received',
    if (pushed > 0) '$pushed sent',
    if (merged > 0) '$merged merged',
    if (deletedHere + deletedThere > 0) '${deletedHere + deletedThere} deleted',
    if (conflicts.isNotEmpty) '${conflicts.length} conflicts',
    if (errors.isNotEmpty) '${errors.length} errors',
  ].join(', ').ifEmpty('up to date');
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// A desktop that answered the discovery broadcast.
class FoundDesktop {
  FoundDesktop(this.host, this.port, this.name);
  final String host;
  final int port;
  final String name;
}

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

HttpClient _client(String? fingerprint, {void Function(String seen)? onCert}) {
  final c = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 5);
  c.badCertificateCallback = (cert, host, port) {
    final seen = certFingerprint(cert.der);
    onCert?.call(seen);
    return fingerprint == null || seen == fingerprint;
  };
  return c;
}

/// Broadcasts on the LAN and returns the desktops that answer within [timeout].
Future<List<FoundDesktop>> discoverDesktops({Duration timeout = const Duration(milliseconds: 1500), int port = defaultDiscoveryPort}) async {
  final found = <String, FoundDesktop>{};
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)..broadcastEnabled = true;
  final done = Completer<void>();
  sock.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final d = sock.receive();
    if (d == null) return;
    try {
      final j = jsonDecode(utf8.decode(d.data));
      if (j is Map && j['agenda'] == 1) found[d.address.address] = FoundDesktop(d.address.address, (j['port'] as num).toInt(), '${j['name']}');
    } on FormatException {
      // not ours
    }
  });
  final q = utf8.encode(discoveryQuery);
  sock.send(q, InternetAddress('255.255.255.255'), port);
  // Also the /24 broadcast of each local interface: some routers drop 255.255.255.255.
  for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in iface.addresses) {
      final p = a.address.split('.');
      if (p.length == 4 && !a.isLoopback) sock.send(q, InternetAddress('${p[0]}.${p[1]}.${p[2]}.255'), port);
    }
  }
  Timer(timeout, () => done.complete());
  await done.future;
  sock.close();
  return found.values.toList();
}

/// Pairs with the desktop at [host] using the code it shows.
Future<(SyncPeer, String? apiKey)> pairWithDesktop(String host, int port, String code, String deviceName) async {
  String? seen;
  final c = _client(null, onCert: (f) => seen = f);
  try {
    final req = await c.postUrl(Uri.https('$host:$port', '/pair'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'code': code.trim(), 'name': deviceName}));
    final res = await req.close();
    final body = jsonDecode(await utf8.decodeStream(res));
    if (res.statusCode != 200 || body is! Map) throw SyncException(body is Map ? '${body['error']}' : 'pairing failed (${res.statusCode})');
    final fp = '${body['fingerprint']}', token = '${body['token']}';
    if (seen != fp || body['mac'] != pairingMac(code.trim(), fp, token)) {
      throw SyncException('The desktop could not prove it is the one showing this code. Pairing refused.');
    }
    return (SyncPeer(host: host, port: port, token: token, fingerprint: fp, name: '${body['name']}'), body['api_key'] as String?);
  } finally {
    c.close(force: true);
  }
}

/// Syncs [roots] (root name -> local directory) with [peer]. State lives in [stateDir].
class SyncClient {
  SyncClient({required this.peer, required this.roots, required this.stateDir, required this.deviceName});

  final SyncPeer peer;
  final Map<String, String> roots;
  final String stateDir;
  final String deviceName;
  final _caches = <String, HashCache>{};

  /// A sync never deletes more than this share of the desktop's files in one go.
  static const maxDeleteShare = 0.2;

  Uri _uri(String path, [Map<String, String>? q]) => Uri(scheme: 'https', host: peer.host, port: peer.port, path: path, queryParameters: q);

  Future<bool> reachable() async {
    final c = _client(peer.fingerprint);
    try {
      final req = await c.getUrl(_uri('/ping'));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode == 200;
    } on Object {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  /// The Anthropic API key the desktop holds, or null.
  Future<String?> fetchApiKey() async {
    final c = _client(peer.fingerprint);
    try {
      final res = await _send(c, 'GET', '/apikey');
      final j = jsonDecode(await utf8.decodeStream(res));
      return res.statusCode == 200 && j is Map ? j['api_key'] as String? : null;
    } on Object {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  Future<SyncReport> sync() async {
    final report = SyncReport();
    final c = _client(peer.fingerprint);
    try {
      for (final e in roots.entries) {
        await _syncRoot(c, e.key, e.value, report);
      }
    } on SocketException catch (e) {
      report.errors.add('desktop not reachable: ${e.message}');
    } on HandshakeException catch (e) {
      report.errors.add('the desktop certificate changed: ${e.message}. Pair again.');
    } on SyncException catch (e) {
      report.errors.add(e.message);
    } on HttpException catch (e) {
      report.errors.add('desktop connection failed: ${e.message}');
    } finally {
      c.close(force: true);
    }
    report.at = DateTime.now();
    if (report.conflicts.isNotEmpty || report.errors.isNotEmpty) await _log(report);
    return report;
  }

  // ---- state -------------------------------------------------------------------

  File _stateFile(String root) => File('$stateDir/$root.json');
  String _basePath(String root, String rel) => '$stateDir/base/$root/$rel';

  Future<Map<String, String>> _loadState(String root) async {
    final f = _stateFile(root);
    if (!await f.exists()) return {};
    try {
      final j = jsonDecode(await f.readAsString());
      return j is Map ? j.map((k, v) => MapEntry('$k', '$v')) : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> _saveState(String root, Map<String, String> s) =>
      writeBytesAtomic(_stateFile(root).path, utf8.encode(jsonEncode(s)));

  Future<void> _log(SyncReport r) async {
    final f = File('$stateDir/sync.log');
    await f.parent.create(recursive: true);
    final lines = [for (final c in r.conflicts) '${r.at.toIso8601String()} conflict: $c', for (final e in r.errors) '${r.at.toIso8601String()} error: $e'];
    await f.writeAsString('${lines.join('\n')}\n', mode: FileMode.append);
  }

  // ---- remote calls --------------------------------------------------------------

  Future<HttpClientResponse> _send(HttpClient c, String method, String path, {Map<String, String>? q, List<int>? body, Map<String, String>? headers}) async {
    final req = await c.openUrl(method, _uri(path, q));
    req.headers.set('authorization', 'Bearer ${peer.token}');
    headers?.forEach(req.headers.set);
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close();
    if (res.statusCode == 401) {
      await res.drain<void>();
      throw SyncException('This phone is no longer paired with the desktop. Pair again.');
    }
    return res;
  }

  Future<Map<String, FileEntry>> _remoteManifest(HttpClient c, String root) async {
    final res = await _send(c, 'GET', '/manifest', q: {'root': root});
    final j = jsonDecode(await utf8.decodeStream(res));
    if (res.statusCode != 200 || j is! Map) throw SyncException('manifest $root: ${res.statusCode}');
    return (j['files'] as Map).map((k, v) => MapEntry('$k', FileEntry.fromJson((v as Map).cast<String, Object?>())));
  }

  Future<(List<int>, int)> _get(HttpClient c, String root, String rel) async {
    final res = await _send(c, 'GET', '/file', q: {'root': root, 'path': rel});
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (res.statusCode != 200) throw SyncException('get $rel: ${res.statusCode}');
    return (bytes, int.tryParse(res.headers.value('x-mtime') ?? '') ?? DateTime.now().millisecondsSinceEpoch);
  }

  /// Returns false when the desktop's copy changed since the manifest (409).
  Future<bool> _put(HttpClient c, String root, String rel, List<int> bytes, String? remoteHash, int mtime) async {
    final res = await _send(c, 'PUT', '/file',
        q: {'root': root, 'path': rel}, body: bytes, headers: {'x-base': remoteHash ?? 'none', 'x-mtime': '$mtime'});
    await res.drain<void>();
    if (res.statusCode == 409) return false;
    if (res.statusCode != 200) throw SyncException('put $rel: ${res.statusCode}');
    return true;
  }

  Future<bool> _delete(HttpClient c, String root, String rel, String remoteHash) async {
    final res = await _send(c, 'DELETE', '/file', q: {'root': root, 'path': rel}, headers: {'x-base': remoteHash});
    await res.drain<void>();
    if (res.statusCode == 409) return false;
    if (res.statusCode != 200) throw SyncException('delete $rel: ${res.statusCode}');
    return true;
  }

  // ---- the sync -------------------------------------------------------------------

  Future<void> _syncRoot(HttpClient c, String root, String dir, SyncReport report) async {
    await Directory(dir).create(recursive: true);
    final local = await scanRoot(root, dir, cache: _caches.putIfAbsent(root, HashCache.new));
    final remote = await _remoteManifest(c, root);
    var base = await _loadState(root);
    // Local files gone but state kept (app data partly lost): start over rather than
    // deleting everything on the desktop.
    if (local.isEmpty && base.isNotEmpty) base = {};

    final toDeleteThere = [
      for (final p in base.keys)
        if (!local.containsKey(p) && remote[p]?.hash == base[p]) p,
    ];
    if (remote.isNotEmpty && toDeleteThere.length > 3 && toDeleteThere.length > remote.length * maxDeleteShare) {
      report.errors.add('$root: refused to delete ${toDeleteThere.length} files on the desktop in one sync');
      return;
    }

    final paths = {...local.keys, ...remote.keys, ...base.keys};
    for (final rel in paths) {
      final l = local[rel], r = remote[rel];
      final lh = l?.hash, rh = r?.hash, bh = base[rel];
      final path = '$dir/$rel';
      try {
        if (lh == rh) {
          if (lh == null) {
            base.remove(rel);
          } else {
            base[rel] = lh;
            if (rel.endsWith('.json') && bh != lh) await _saveBase(root, rel, await File(path).readAsBytes());
          }
        } else if (lh == bh) {
          // Only the desktop changed.
          if (rh == null) {
            await File(path).delete();
            await _dropBase(root, rel);
            base.remove(rel);
            report.deletedHere++;
          } else {
            await _pull(c, root, rel, path, base);
            report.pulled++;
          }
        } else if (rh == bh) {
          // Only this device changed.
          if (lh == null) {
            if (await _delete(c, root, rel, rh!)) {
              await _dropBase(root, rel);
              base.remove(rel);
              report.deletedThere++;
            }
          } else {
            final bytes = await File(path).readAsBytes();
            if (await _put(c, root, rel, bytes, rh, l!.mtime)) {
              base[rel] = lh;
              if (rel.endsWith('.json')) await _saveBase(root, rel, bytes);
              report.pushed++;
            }
          }
        } else if (lh == null) {
          await _pull(c, root, rel, path, base); // deleted here, changed there: keep the change
          report.pulled++;
        } else if (rh == null) {
          final bytes = await File(path).readAsBytes();
          if (await _put(c, root, rel, bytes, null, l!.mtime)) {
            base[rel] = lh;
            report.pushed++;
          }
        } else if (rel.endsWith('.json')) {
          await _merge(c, root, rel, path, l!, r!, base, report);
        } else {
          await _conflictCopy(c, root, rel, path, l!, r!, base, report);
        }
      } on FileSystemException catch (e) {
        report.errors.add('$rel: ${e.message}');
      } on SyncException catch (e) {
        report.errors.add(e.message);
      }
    }
    await _saveState(root, base);
  }

  Future<void> _pull(HttpClient c, String root, String rel, String path, Map<String, String> base) async {
    final (bytes, mtime) = await _get(c, root, rel);
    await writeBytesAtomic(path, bytes, mtime: DateTime.fromMillisecondsSinceEpoch(mtime));
    base[rel] = hashBytes(bytes);
    if (rel.endsWith('.json')) await _saveBase(root, rel, bytes);
  }

  Future<void> _saveBase(String root, String rel, List<int> bytes) => writeBytesAtomic(_basePath(root, rel), bytes);

  Future<void> _dropBase(String root, String rel) async {
    final f = File(_basePath(root, rel));
    if (await f.exists()) await f.delete();
  }

  Future<void> _merge(HttpClient c, String root, String rel, String path, FileEntry l, FileEntry r, Map<String, String> base, SyncReport report) async {
    final (remoteBytes, _) = await _get(c, root, rel);
    final localBytes = await File(path).readAsBytes();
    final baseFile = File(_basePath(root, rel));
    final baseBytes = await baseFile.exists() ? await baseFile.readAsBytes() : null;
    final localWins = l.mtime >= r.mtime;
    final merged = await Isolate.run(() => _mergeBytes(rel, baseBytes, localBytes, remoteBytes, localWins));
    if (merged == null) {
      // Not mergeable (broken JSON or the result fails validation): keep both files.
      await _conflictCopy(c, root, rel, path, l, r, base, report);
      return;
    }
    final (bytes, notes) = merged;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!await _put(c, root, rel, bytes, r.hash, now)) return; // changed again, next round
    await writeBytesAtomic(path, bytes, mtime: DateTime.fromMillisecondsSinceEpoch(now));
    base[rel] = hashBytes(bytes);
    await _saveBase(root, rel, bytes);
    report.merged++;
    for (final n in notes) {
      report.conflicts.add('$root/$rel $n');
    }
  }

  /// Both sides changed a file that cannot be merged: the newer one stays under the
  /// real name, the other is kept next to it as `<name>.conflict-<device>-<time>.<ext>`.
  Future<void> _conflictCopy(HttpClient c, String root, String rel, String path, FileEntry l, FileEntry r, Map<String, String> base, SyncReport report) async {
    final stamp = DateTime.now().toIso8601String().substring(0, 16).replaceAll(RegExp('[-:]'), '').replaceAll('T', '-');
    final dot = rel.lastIndexOf('.');
    final slash = rel.lastIndexOf('/');
    String copyName(String who) =>
        dot > slash ? '${rel.substring(0, dot)}.conflict-$who-$stamp${rel.substring(dot)}' : '$rel.conflict-$who-$stamp';
    final (remoteBytes, remoteMtime) = await _get(c, root, rel);
    final localBytes = await File(path).readAsBytes();
    if (l.mtime >= r.mtime) {
      // Keep ours; the desktop's version becomes a copy on both sides.
      await writeBytesAtomic('${roots[root]}/${copyName(peer.name.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''))}', remoteBytes);
      if (!await _put(c, root, rel, localBytes, r.hash, l.mtime)) return;
      base[rel] = l.hash;
    } else {
      await writeBytesAtomic('${roots[root]}/${copyName(deviceName.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''))}', localBytes);
      await writeBytesAtomic(path, remoteBytes, mtime: DateTime.fromMillisecondsSinceEpoch(remoteMtime));
      base[rel] = r.hash;
    }
    if (rel.endsWith('.json')) await _saveBase(root, rel, await File(path).readAsBytes());
    report.conflicts.add('$root/$rel: changed on both devices, both versions kept');
  }
}

/// Merges the three versions of a JSON file; null when that is not possible.
(List<int>, List<String>)? _mergeBytes(String rel, List<int>? baseBytes, List<int> localBytes, List<int> remoteBytes, bool localWins) {
  try {
    final result = mergeJson(
      baseBytes == null ? const <String, Object?>{} : jsonDecode(utf8.decode(baseBytes)),
      jsonDecode(utf8.decode(localBytes)),
      jsonDecode(utf8.decode(remoteBytes)),
      localWins: localWins,
    );
    final v = result.value;
    if (v is! Map<String, Object?>) return null;
    final problems = rel.endsWith('/task.json')
        ? validateTaskJson(v)
        : rel.endsWith('/project.json')
        ? validateProjectJson(v)
        : rel == 'events.json'
        ? validateEventsJson(v)
        : rel == 'recurring.json'
        ? validateRecurringJson(v)
        : const <String>[];
    if (problems.isNotEmpty) return null;
    return (utf8.encode(encodeJson(v)), result.conflicts);
  } on FormatException {
    return null;
  }
}
