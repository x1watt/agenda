/// What a sync root contains: every synced file with its hash, size and mtime.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// One synced file.
class FileEntry {
  const FileEntry(this.hash, this.size, this.mtime);
  final String hash;
  final int size;

  /// Milliseconds since epoch.
  final int mtime;

  factory FileEntry.fromJson(Map<String, Object?> j) =>
      FileEntry('${j['h']}', (j['s'] as num?)?.toInt() ?? 0, (j['m'] as num?)?.toInt() ?? 0);

  Map<String, Object?> toJson() => {'h': hash, 's': size, 'm': mtime};
}

/// The two roots that are synced and which files inside them belong to the sync.
/// Every device of the account gets what the automation needs: the projects, the
/// credentials (`accounts/`), the prompts and the shared checker state (`shared/`).
/// Run logs, code and build trees stay on the device that made them.
class SyncRoots {
  static const agenda = 'agenda';
  static const personal = 'personal';
  static const all = [agenda, personal];

  /// Folders of the agenda root synced with everything inside them.
  static const dirs = {'projects', 'accounts', 'prompts', 'shared'};

  /// Single files of the agenda root that are synced.
  static const files = {'general.json', 'events.json', 'recurring.json', 'CLAUDE.md', 'docs/format.md'};

  /// Files written with mode 600: credentials and everything personal.
  static bool isPrivate(String root, String rel) => root == personal || rel.startsWith('accounts/');

  /// True when [rel] (a `/`-separated path inside [root]) is synced.
  static bool includes(String root, String rel) {
    if (rel.isEmpty || rel.startsWith('/') || rel.split('/').any((s) => s == '..' || s == '.' || s.isEmpty)) return false;
    final parts = rel.split('/');
    final name = parts.last;
    if (name.contains('.tmp-') || name.endsWith('.lock') || name == '.DS_Store' || name.startsWith('.~')) return false;
    if (parts.any((p) => p == '.sync' || p == 'build' || p == '.git')) return false;
    if (root == agenda) {
      // CLAUDE.md and the format reference go along so Claude on the phone knows the rules.
      return dirs.contains(parts.first) && parts.length > 1 || files.contains(rel);
    }
    return root == personal;
  }
}

/// Remembers hashes by (size, mtime) so an unchanged file is not read again.
class HashCache {
  final _cache = <String, (int, int, String)>{};

  String? lookup(String path, int size, int mtime) {
    final c = _cache[path];
    return c != null && c.$1 == size && c.$2 == mtime ? c.$3 : null;
  }

  void store(String path, int size, int mtime, String hash) => _cache[path] = (size, mtime, hash);

  Map<String, (int, int, String)> get snapshot => Map.of(_cache);

  void replace(Map<String, (int, int, String)> m) => _cache
    ..clear()
    ..addAll(m);
}

/// Scans [dir] as sync root [root]. Hashing runs in a separate isolate.
Future<Map<String, FileEntry>> scanRoot(String root, String dir, {HashCache? cache}) async {
  final known = cache?.snapshot ?? const <String, (int, int, String)>{};
  final (entries, fresh) = await Isolate.run(() => _scan(root, dir, known));
  cache?.replace(fresh);
  return entries;
}

(Map<String, FileEntry>, Map<String, (int, int, String)>) _scan(String root, String dir, Map<String, (int, int, String)> known) {
  final out = <String, FileEntry>{};
  final fresh = <String, (int, int, String)>{};
  final base = Directory(dir);
  if (!base.existsSync()) return (out, fresh);
  // The desktop agenda folder also holds code and build trees: walk only what is synced.
  final candidates = root == SyncRoots.agenda
      ? [
          for (final d in SyncRoots.dirs)
            if (Directory('$dir/$d').existsSync()) ...Directory('$dir/$d').listSync(recursive: true, followLinks: false),
          for (final f in SyncRoots.files)
            if (File('$dir/$f').existsSync()) File('$dir/$f'),
        ]
      : base.listSync(recursive: true, followLinks: false);
  for (final e in candidates) {
    if (e is! File) continue;
    final rel = e.path.substring(dir.length + 1);
    if (!SyncRoots.includes(root, rel)) continue;
    final FileStat st;
    try {
      st = e.statSync();
    } on FileSystemException {
      continue;
    }
    final mtime = st.modified.millisecondsSinceEpoch;
    final k = known[e.path];
    String hash;
    if (k != null && k.$1 == st.size && k.$2 == mtime) {
      hash = k.$3;
    } else {
      try {
        hash = sha256.convert(e.readAsBytesSync()).toString();
      } on FileSystemException {
        continue; // vanished while scanning
      }
    }
    fresh[e.path] = (st.size, mtime, hash);
    out[rel] = FileEntry(hash, st.size, mtime);
  }
  return (out, fresh);
}

String hashBytes(List<int> bytes) => sha256.convert(bytes).toString();
