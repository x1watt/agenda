import 'dart:io';
import 'dart:math';

/// Task UID alphabet: no I, O, 0 or 1, so ids survive handwriting and phone calls.
const uidAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

final uidPattern = RegExp('^[$uidAlphabet]{3}-[$uidAlphabet]{3}\$');

/// A task folder: `<UID>-<slug>`.
final taskFolderPattern = RegExp('^([$uidAlphabet]{3}-[$uidAlphabet]{3})-([a-z0-9-]+)\$');

final projectIdPattern = RegExp(r'^[A-Za-z0-9-]+$');

bool isValidUid(String s) => uidPattern.hasMatch(s);

bool isValidProjectId(String s) => projectIdPattern.hasMatch(s);

/// The UID part of a task folder name, or null if the name is not a task folder.
String? uidOfFolder(String name) => taskFolderPattern.firstMatch(name)?.group(1);

/// A fresh `XXX-XXX` id not in [taken].
String generateUid(Set<String> taken, {Random? rng}) {
  final r = rng ?? Random.secure();
  for (var attempt = 0; attempt < 1000; attempt++) {
    final b = StringBuffer();
    for (var i = 0; i < 6; i++) {
      if (i == 3) b.write('-');
      b.write(uidAlphabet[r.nextInt(uidAlphabet.length)]);
    }
    final uid = b.toString();
    if (!taken.contains(uid)) return uid;
  }
  throw StateError('could not find a free UID');
}

/// Every UID in use under [projectsDir]: task folder names plus the `uid` field
/// of each readable task.json (a broken file still holds its UID).
Future<Set<String>> takenUids(String projectsDir) async {
  final out = <String>{};
  final root = Directory(projectsDir);
  if (!await root.exists()) return out;
  await for (final p in root.list()) {
    if (p is! Directory) continue;
    await for (final t in p.list()) {
      if (t is! Directory) continue;
      final name = t.path.split('/').last;
      final uid = uidOfFolder(name);
      if (uid != null) out.add(uid);
      final f = File('${t.path}/task.json');
      if (await f.exists()) {
        final m = RegExp(r'"uid"\s*:\s*"([^"]+)"').firstMatch(await f.readAsString());
        if (m != null) out.add(m.group(1)!);
      }
    }
  }
  return out;
}

const _umlauts = {'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss', 'é': 'e', 'è': 'e', 'ê': 'e', 'á': 'a', 'à': 'a', 'ã': 'a', 'â': 'a', 'ç': 'c', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'í': 'i', 'ú': 'u'};

/// Folder-safe slug of a task name: lowercase `[a-z0-9-]`, at most 40 chars.
String slugFor(String name) {
  var s = name.toLowerCase();
  _umlauts.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 40) {
    s = s.substring(0, 40);
    final cut = s.lastIndexOf('-');
    if (cut > 20) s = s.substring(0, cut);
  }
  return s.isEmpty ? 'task' : s;
}

String taskFolderName(String uid, String name) => '$uid-${slugFor(name)}';

String todayIso() => DateTime.now().toIso8601String().substring(0, 10);

String nowIso() => DateTime.now().toIso8601String();
