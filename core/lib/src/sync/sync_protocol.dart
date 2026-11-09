/// The file-sync protocol between two devices of the same account, independent of
/// the transport. Every device runs a [SyncHost] that answers JSON requests about
/// its files; the device that drives a sync talks to the other's host through a
/// [SyncTransport] (a [RequestTransport] over Reticulum/LXMF in the app, a direct
/// call in tests).
///
/// Requests (`op`) and replies:
///
///   manifest {root}                         -> {files: {rel: {h, s, m}}}
///   get      {root, path, off}              -> {h, m, size, off, data(base64)}   one chunk
///   put      {root, path, base, m, id, off, total, data(base64)}
///                                           -> {ok, more} while chunks are missing,
///                                              {ok, h} once written, {error: changed, hash}
///   delete   {root, path, base}             -> {ok} | {error: changed, hash}
///
/// `base` is the hash the writer saw (`none` for a file it believes absent): a write
/// only happens when the host's file still has that hash, so nothing is overwritten
/// blindly. Any other failure is `{error: <text>}`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../paths.dart' show writeBytesAtomic;
import 'manifest.dart';

/// Bytes of file content per request or reply (before base64).
const syncChunkBytes = 192 * 1024;

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a device can ask another device's host.
abstract class SyncTransport {
  Future<Map<String, FileEntry>> manifest(String root);

  /// The whole file and its mtime (milliseconds since the epoch).
  Future<(List<int>, int)> get(String root, String rel);

  /// Writes [bytes] when the remote file still has [baseHash] (null: absent).
  /// False when it changed in between.
  Future<bool> put(String root, String rel, List<int> bytes, String? baseHash, int mtime);

  /// Deletes when the remote file still has [baseHash]; false when it changed.
  Future<bool> delete(String root, String rel, String baseHash);
}

/// Sends one request and waits for its reply; throws [SyncException] when the
/// other device cannot be reached.
typedef SyncCall = Future<Map<String, Object?>> Function(Map<String, Object?> request);

/// [SyncTransport] over any request/reply channel, splitting files into chunks.
class RequestTransport implements SyncTransport {
  RequestTransport(this.call, {this.chunkBytes = syncChunkBytes});

  final SyncCall call;
  final int chunkBytes;
  int _uploads = 0;

  Future<Map<String, Object?>> _ok(Map<String, Object?> req) async {
    final r = await call(req);
    final err = r['error'];
    if (err != null && err != 'changed') throw SyncException('${req['op']} ${req['path'] ?? req['root']}: $err');
    return r;
  }

  @override
  Future<Map<String, FileEntry>> manifest(String root) async {
    final r = await _ok({'op': 'manifest', 'root': root});
    final files = r['files'];
    if (files is! Map) throw SyncException('manifest $root: no file list');
    return files.map((k, v) => MapEntry('$k', FileEntry.fromJson((v as Map).cast<String, Object?>())));
  }

  @override
  Future<(List<int>, int)> get(String root, String rel) async {
    final out = BytesBuilder(copy: false);
    String? hash;
    var mtime = 0;
    while (true) {
      final r = await _ok({'op': 'get', 'root': root, 'path': rel, 'off': out.length});
      final h = '${r['h']}';
      if (hash != null && h != hash) {
        // The file changed between two chunks: start over.
        out.clear();
        hash = null;
        continue;
      }
      hash = h;
      mtime = (r['m'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
      out.add(base64.decode('${r['data']}'));
      final size = (r['size'] as num).toInt();
      if (out.length >= size) break;
    }
    final bytes = out.takeBytes();
    if (hashBytes(bytes) != hash) throw SyncException('get $rel: content does not match its hash');
    return (bytes, mtime);
  }

  @override
  Future<bool> put(String root, String rel, List<int> bytes, String? baseHash, int mtime) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_uploads++}';
    var off = 0;
    do {
      final end = (off + chunkBytes).clamp(0, bytes.length);
      final r = await _ok({
        'op': 'put',
        'root': root,
        'path': rel,
        'base': baseHash ?? 'none',
        'm': mtime,
        'id': id,
        'off': off,
        'total': bytes.length,
        'data': base64.encode(bytes.sublist(off, end)),
      });
      if (r['error'] == 'changed') return false;
      off = end;
    } while (off < bytes.length);
    return true;
  }

  @override
  Future<bool> delete(String root, String rel, String baseHash) async {
    final r = await _ok({'op': 'delete', 'root': root, 'path': rel, 'base': baseHash});
    return r['error'] != 'changed';
  }
}

/// Answers sync requests about [roots] (root name -> directory). The transport
/// decides who may ask; the host only keeps requests inside the synced files.
class SyncHost {
  SyncHost({required this.roots, this.onChanged, this.chunkBytes = syncChunkBytes});

  final Map<String, String> roots;

  /// Called after a peer wrote or deleted a file (root, path).
  final void Function(String root, String path)? onChanged;
  final int chunkBytes;

  final _caches = <String, HashCache>{};
  final _uploads = <String, _Upload>{};

  Future<Map<String, Object?>> handle(Map<String, Object?> req) async {
    try {
      return await _handle(req);
    } on FileSystemException catch (e) {
      return {'error': e.message};
    } on FormatException catch (e) {
      return {'error': 'bad request: ${e.message}'};
    }
  }

  Future<Map<String, Object?>> _handle(Map<String, Object?> req) async {
    final op = req['op'];
    final root = '${req['root'] ?? ''}';
    final dir = roots[root];
    if (dir == null) return {'error': 'unknown root'};
    if (op == 'manifest') {
      final files = await scanRoot(root, dir, cache: _caches.putIfAbsent(root, HashCache.new));
      return {'files': {for (final e in files.entries) e.key: e.value.toJson()}};
    }
    final rel = '${req['path'] ?? ''}';
    if (!SyncRoots.includes(root, rel)) return {'error': 'path not synced'};
    final file = File('$dir/$rel');
    switch (op) {
      case 'get':
        if (!await file.exists()) return {'error': 'not found'};
        final bytes = await file.readAsBytes();
        final off = ((req['off'] as num?)?.toInt() ?? 0).clamp(0, bytes.length);
        final end = (off + chunkBytes).clamp(0, bytes.length);
        return {
          'h': hashBytes(bytes),
          'm': (await file.lastModified()).millisecondsSinceEpoch,
          'size': bytes.length,
          'off': off,
          'data': base64.encode(bytes.sublist(off, end)),
        };
      case 'put':
        return _put(root, rel, file, req);
      case 'delete':
        final current = await _hashOf(file);
        if ('${req['base']}' != current) return {'error': 'changed', 'hash': current};
        if (await file.exists()) await file.delete();
        onChanged?.call(root, rel);
        return {'ok': true};
    }
    return {'error': 'unknown op'};
  }

  Future<Map<String, Object?>> _put(String root, String rel, File file, Map<String, Object?> req) async {
    final now = DateTime.now();
    _uploads.removeWhere((_, u) => now.difference(u.started) > const Duration(minutes: 15));
    final key = '$root/$rel/${req['id']}';
    final off = (req['off'] as num?)?.toInt() ?? 0;
    final total = (req['total'] as num?)?.toInt() ?? 0;
    final chunk = base64.decode('${req['data'] ?? ''}');
    final up = off == 0 ? (_uploads[key] = _Upload(now)) : _uploads[key];
    if (up == null || up.bytes.length != off) {
      _uploads.remove(key);
      return {'error': 'upload out of order'};
    }
    up.bytes.add(chunk);
    if (up.bytes.length < total) return {'ok': true, 'more': true};
    _uploads.remove(key);
    final current = await _hashOf(file);
    if ('${req['base']}' != current) return {'error': 'changed', 'hash': current};
    final bytes = up.bytes.takeBytes();
    final m = (req['m'] as num?)?.toInt();
    await writeBytesAtomic(file.path, bytes, mtime: m == null ? null : DateTime.fromMillisecondsSinceEpoch(m), private: SyncRoots.isPrivate(root, rel));
    onChanged?.call(root, rel);
    return {'ok': true, 'h': hashBytes(bytes)};
  }

  static Future<String> _hashOf(File f) async => await f.exists() ? hashBytes(await f.readAsBytes()) : 'none';
}

class _Upload {
  _Upload(this.started);
  final DateTime started;
  final bytes = BytesBuilder(copy: false);
}
