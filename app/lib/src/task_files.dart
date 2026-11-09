import 'dart:io';

import 'package:agenda_core/agenda_core.dart';

/// A file (or folder) that belongs to a task and can be reviewed in the app.
class TaskFile {
  TaskFile({required this.path, required this.rel, required this.isDir, required this.modified, this.ref});

  /// Absolute, canonical path.
  final String path;

  /// Path relative to the task folder, as stored in task.json.
  final String rel;
  final bool isDir;
  final DateTime modified;

  /// Review state from task.json, if the file is listed there.
  final TaskFileRef? ref;

  String get name => path.split('/').where((s) => s.isNotEmpty).last;

  bool get isText => !isDir && textExtensions.contains(name.split('.').last.toLowerCase());

  bool get isMarkdown => name.toLowerCase().endsWith('.md');

  /// Approved and not changed since.
  bool get approved => ref != null && ref!.approved && (ref!.when == null || !modified.isAfter(ref!.when!));

  /// Approved once, but edited afterwards.
  bool get changedSinceApproval => ref != null && ref!.approved && ref!.when != null && modified.isAfter(ref!.when!);
}

const textExtensions = {'md', 'txt', 'json', 'csv', 'eml', 'yaml', 'yml', 'html', 'xml'};
const _extensions = 'md|txt|pdf|odt|ods|docx|doc|xlsx|json|csv|eml|html|png|jpg|jpeg';

/// File paths mentioned in free text: `../car/post/x.md`, `email.md`, `insurance/forms/`.
final _filePattern = RegExp(r'(?:~/|\.\./|\./|/)?(?:[\w.\-]+/)*[\w.\-]+\.(?:' + _extensions + r')\b');

/// Folders: at least one segment ending in "/", followed by a separator or the end.
final _dirPattern = RegExp(r'((?:~/|\.\./|\./)?(?:[\w.\-]+/)+)(?=[\s,;:)`"]|$)');

Iterable<String> mentionedPaths(String text) sync* {
  for (final m in _filePattern.allMatches(text)) {
    yield m.group(0)!;
  }
  for (final m in _dirPattern.allMatches(text)) {
    yield m.group(1)!;
  }
}

const _bookkeeping = {'task.json', 'project.json', 'general.json'};

/// Resolves the files of [task]: everything in its folder, the explicit `files`
/// list, and paths mentioned in its text and in [extraTexts] (e.g. its
/// conversation), keeping only those that exist.
Future<List<TaskFile>> resolveTaskFiles({
  required String agendaDir,
  required Project project,
  required AgendaTask task,
  Iterable<String> extraTexts = const [],
}) async {
  final agenda = normalizePath(agendaDir);
  final workspace = normalizePath('$agenda/..');
  final taskDir = task.dir.isEmpty ? null : normalizePath(task.dir);
  final projectDir = project.dir.isEmpty ? null : normalizePath(project.dir);
  final home = AgendaPaths.home;

  final refs = <String, TaskFileRef>{};
  final candidates = <String>[];
  if (taskDir != null && await Directory(taskDir).exists()) {
    await for (final e in Directory(taskDir).list()) {
      final name = e.path.split('/').last;
      if (_bookkeeping.contains(name) || name.startsWith('.') || name.contains('.tmp-')) continue;
      candidates.add(e.path);
    }
  }
  for (final f in task.files) {
    final abs = f.path.startsWith('/') ? f.path : '${taskDir ?? agenda}/${f.path}';
    refs[await _canonical(normalizePath(abs))] = f;
    candidates.add(f.path);
  }
  for (final text in [task.nextStep ?? '', task.waitingOn ?? '', ...task.history.map((h) => h.text), ...extraTexts]) {
    candidates.addAll(mentionedPaths(text));
  }

  final found = <String, TaskFile>{};
  for (final c in candidates) {
    final bases = c.startsWith('/')
        ? ['']
        : c.startsWith('~/')
        ? [home]
        : [?taskDir, ?projectDir, agenda, workspace];
    final rel = c.startsWith('~/') ? c.substring(2) : c;
    String? hit;
    for (final base in bases) {
      final p = normalizePath(base.isEmpty ? rel : '$base/$rel');
      if (await FileSystemEntity.type(p) != FileSystemEntityType.notFound) {
        hit = p;
        break;
      }
    }
    // A bare file name ("email.md"): look for it under the task and the project folder.
    if (hit == null && !rel.contains('/')) {
      for (final root in [?taskDir, ?projectDir]) {
        hit = await _findByName(root, rel, 3);
        if (hit != null) break;
      }
    }
    if (hit == null) continue;
    hit = await _canonical(hit);
    if (found.containsKey(hit)) continue;
    // Never surface secrets, the old files, or the bookkeeping files themselves.
    if (hit.startsWith('$agenda/accounts') || hit.startsWith('$agenda/legacy') || _bookkeeping.contains(hit.split('/').last)) {
      continue;
    }
    final stat = await FileStat.stat(hit);
    if (stat.type == FileSystemEntityType.notFound) continue;
    found[hit] = TaskFile(
      path: hit,
      rel: relativeTo(taskDir ?? agenda, hit),
      isDir: stat.type == FileSystemEntityType.directory,
      modified: stat.modified,
      ref: refs[hit],
    );
  }
  final list = found.values.toList()
    ..sort((a, b) {
      // Files waiting for review first, then by name.
      final ra = a.approved ? 1 : 0;
      final rb = b.approved ? 1 : 0;
      return ra != rb ? ra - rb : a.name.compareTo(b.name);
    });
  return list;
}

Future<String> _canonical(String path) async {
  try {
    return normalizePath(await File(path).resolveSymbolicLinks());
  } on FileSystemException {
    return path;
  }
}

Future<String?> _findByName(String root, String name, int depth) async {
  if (depth < 0 || !await Directory(root).exists()) return null;
  final subdirs = <String>[];
  await for (final e in Directory(root).list()) {
    final n = e.path.split('/').last;
    if (n == name) return normalizePath(e.path);
    if (e is Directory && !n.startsWith('.')) subdirs.add(e.path);
  }
  for (final d in subdirs) {
    final hit = await _findByName(d, name, depth - 1);
    if (hit != null) return hit;
  }
  return null;
}
