/// One sync between this device and another device of the same account. It compares
/// its files, the other device's files and the state of the last sync with that
/// device (the base), then pulls, pushes, deletes or merges. Each peer has its own
/// base under [SyncSession.stateDir], so any number of devices converge pair by pair.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../paths.dart' show writeBytesAtomic;
import '../store.dart' show encodeJson, validateEventsJson, validateProjectJson, validateRecurringJson, validateTaskJson;
import 'json_merge.dart';
import 'manifest.dart';
import 'sync_protocol.dart';

/// What one sync did.
class SyncReport {
  int pulled = 0, pushed = 0, deletedHere = 0, deletedThere = 0, merged = 0;
  final conflicts = <String>[];
  final errors = <String>[];
  DateTime at = DateTime.now();

  int get changes => pulled + pushed + deletedHere + deletedThere + merged;

  /// Files on this device changed (the app reloads).
  bool get changedHere => pulled + merged + deletedHere + conflicts.length > 0;

  @override
  String toString() {
    final s = [
      if (pulled > 0) '$pulled received',
      if (pushed > 0) '$pushed sent',
      if (merged > 0) '$merged merged',
      if (deletedHere + deletedThere > 0) '${deletedHere + deletedThere} deleted',
      if (conflicts.isNotEmpty) '${conflicts.length} conflicts',
      if (errors.isNotEmpty) '${errors.length} errors',
    ].join(', ');
    return s.isEmpty ? 'up to date' : s;
  }
}

/// Syncs [roots] (root name -> local directory) with one peer through [transport].
class SyncSession {
  SyncSession({
    required this.transport,
    required this.roots,
    required this.stateDir,
    required this.deviceName,
    required this.peerName,
  });

  final SyncTransport transport;
  final Map<String, String> roots;

  /// The base of this peer: hashes per file and the last synced JSON files.
  final String stateDir;
  final String deviceName;
  final String peerName;
  final _caches = <String, HashCache>{};

  /// A sync never deletes more than this share of the peer's files in one go.
  static const maxDeleteShare = 0.2;

  Future<SyncReport> sync() async {
    final report = SyncReport();
    try {
      for (final e in roots.entries) {
        await _syncRoot(e.key, e.value, report);
      }
    } on SyncException catch (e) {
      report.errors.add(e.message);
    } on IOException catch (e) {
      report.errors.add('$peerName: $e');
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

  /// True when the local file still has [hash] (null: still absent). Another peer may
  /// have written it since the scan; then this file waits for the next round.
  static Future<bool> _unchanged(String path, String? hash) async {
    final f = File(path);
    if (!await f.exists()) return hash == null;
    return hash != null && hashBytes(await f.readAsBytes()) == hash;
  }

  // ---- the sync -------------------------------------------------------------------

  Future<void> _syncRoot(String root, String dir, SyncReport report) async {
    await Directory(dir).create(recursive: true);
    final local = await scanRoot(root, dir, cache: _caches.putIfAbsent(root, HashCache.new));
    final remote = await transport.manifest(root);
    var base = await _loadState(root);
    // Local files gone but state kept (app data partly lost): start over rather than
    // deleting everything on the peer.
    if (local.isEmpty && base.isNotEmpty) base = {};

    final toDeleteThere = [
      for (final p in base.keys)
        if (!local.containsKey(p) && remote[p]?.hash == base[p]) p,
    ];
    if (remote.isNotEmpty && toDeleteThere.length > 3 && toDeleteThere.length > remote.length * maxDeleteShare) {
      report.errors.add('$root: refused to delete ${toDeleteThere.length} files on $peerName in one sync');
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
          // Only the peer changed.
          if (!await _unchanged(path, lh)) continue;
          if (rh == null) {
            await File(path).delete();
            await pruneEmptyParents(path, dir);
            await _dropBase(root, rel);
            base.remove(rel);
            report.deletedHere++;
          } else {
            await _pull(root, rel, path, base);
            report.pulled++;
          }
        } else if (rh == bh) {
          // Only this device changed.
          if (lh == null) {
            if (await transport.delete(root, rel, rh!)) {
              await _dropBase(root, rel);
              base.remove(rel);
              report.deletedThere++;
            }
          } else {
            final bytes = await File(path).readAsBytes();
            if (hashBytes(bytes) != lh) continue; // changed since the scan
            if (await transport.put(root, rel, bytes, rh, l!.mtime)) {
              base[rel] = lh;
              if (rel.endsWith('.json')) await _saveBase(root, rel, bytes);
              report.pushed++;
            }
          }
        } else if (lh == null) {
          if (!await _unchanged(path, null)) continue;
          await _pull(root, rel, path, base); // deleted here, changed there: keep the change
          report.pulled++;
        } else if (rh == null) {
          final bytes = await File(path).readAsBytes();
          if (hashBytes(bytes) != lh) continue;
          if (await transport.put(root, rel, bytes, null, l!.mtime)) {
            base[rel] = lh;
            if (rel.endsWith('.json')) await _saveBase(root, rel, bytes);
            report.pushed++;
          }
        } else if (rel.endsWith('.json')) {
          await _merge(root, rel, path, l!, r!, base, report);
        } else {
          await _conflictCopy(root, rel, path, l!, r!, base, report);
        }
      } on FileSystemException catch (e) {
        report.errors.add('$rel: ${e.message}');
      } on SyncException catch (e) {
        report.errors.add(e.message);
      }
    }
    await _saveState(root, base);
  }

  Future<void> _pull(String root, String rel, String path, Map<String, String> base) async {
    final (bytes, mtime) = await transport.get(root, rel);
    await writeBytesAtomic(path, bytes, mtime: DateTime.fromMillisecondsSinceEpoch(mtime), private: SyncRoots.isPrivate(root, rel));
    base[rel] = hashBytes(bytes);
    if (rel.endsWith('.json')) await _saveBase(root, rel, bytes);
  }

  Future<void> _saveBase(String root, String rel, List<int> bytes) => writeBytesAtomic(_basePath(root, rel), bytes);

  Future<void> _dropBase(String root, String rel) async {
    final f = File(_basePath(root, rel));
    if (await f.exists()) await f.delete();
  }

  Future<void> _merge(String root, String rel, String path, FileEntry l, FileEntry r, Map<String, String> base, SyncReport report) async {
    final (remoteBytes, _) = await transport.get(root, rel);
    final localBytes = await File(path).readAsBytes();
    if (hashBytes(localBytes) != l.hash) return; // changed since the scan, next round
    final baseFile = File(_basePath(root, rel));
    final baseBytes = await baseFile.exists() ? await baseFile.readAsBytes() : null;
    final localWins = l.mtime >= r.mtime;
    final merged = await Isolate.run(() => _mergeBytes(rel, baseBytes, localBytes, remoteBytes, localWins));
    if (merged == null) {
      // Not mergeable (broken JSON or the result fails validation): keep both files.
      await _conflictCopy(root, rel, path, l, r, base, report);
      return;
    }
    final (bytes, notes) = merged;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!await transport.put(root, rel, bytes, hashBytes(remoteBytes), now)) return; // changed again, next round
    if (!await _unchanged(path, l.hash)) return; // the next round merges again
    await writeBytesAtomic(path, bytes, mtime: DateTime.fromMillisecondsSinceEpoch(now), private: SyncRoots.isPrivate(root, rel));
    base[rel] = hashBytes(bytes);
    await _saveBase(root, rel, bytes);
    report.merged++;
    for (final n in notes) {
      report.conflicts.add('$root/$rel $n');
    }
  }

  /// Both sides changed a file that cannot be merged: the newer one stays under the
  /// real name, the other is kept next to it as `<name>.conflict-<device>-<time>.<ext>`.
  Future<void> _conflictCopy(String root, String rel, String path, FileEntry l, FileEntry r, Map<String, String> base, SyncReport report) async {
    final stamp = DateTime.now().toIso8601String().substring(0, 16).replaceAll(RegExp('[-:]'), '').replaceAll('T', '-');
    final dot = rel.lastIndexOf('.');
    final slash = rel.lastIndexOf('/');
    String copyName(String who) {
      final w = who.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      return dot > slash ? '${rel.substring(0, dot)}.conflict-$w-$stamp${rel.substring(dot)}' : '$rel.conflict-$w-$stamp';
    }

    final (remoteBytes, remoteMtime) = await transport.get(root, rel);
    final localBytes = await File(path).readAsBytes();
    if (hashBytes(localBytes) != l.hash) return;
    if (l.mtime >= r.mtime) {
      // Keep ours; the peer's version becomes a copy on both sides.
      await writeBytesAtomic('${roots[root]}/${copyName(peerName)}', remoteBytes, private: SyncRoots.isPrivate(root, rel));
      if (!await transport.put(root, rel, localBytes, hashBytes(remoteBytes), l.mtime)) return;
      base[rel] = l.hash;
    } else {
      final private = SyncRoots.isPrivate(root, rel);
      await writeBytesAtomic('${roots[root]}/${copyName(deviceName)}', localBytes, private: private);
      await writeBytesAtomic(path, remoteBytes, mtime: DateTime.fromMillisecondsSinceEpoch(remoteMtime), private: private);
      base[rel] = hashBytes(remoteBytes);
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
