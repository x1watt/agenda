/// One-off migration from the single tasks.json + threads.json + sibling project
/// folders to projects/<id>/ with project.json, task folders, sources/ and data/.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'ids.dart';
import 'model.dart';
import 'paths.dart';
import 'store.dart';

/// Folders (relative to the old project folder) whose content is user input and
/// goes to `sources/`; everything else goes to `data/` or a task folder. Keyed
/// by new project id, e.g. `{'car': ['invoices', 'insurance/forms']}`. Empty by
/// default: a setup that migrates passes its own mapping to [migrateLegacy].
const defaultSourceFolders = <String, List<String>>{};

class MigrationReport {
  final log = <String>[];
  final warnings = <String>[];
  final unmappedLinks = <String>[];

  /// `project:<oldId>` -> new id, `<oldPid>/<oldTid>` -> uid.
  final idMap = <String, String>{};

  /// Absolute old path -> absolute new path (files and folders).
  final moves = <String, String>{};
  bool applied = false;
  int taskCount = 0;
}

class _ProjectPlan {
  _ProjectPlan({required this.oldId, required this.newId, required this.oldDir, required this.newDir});
  final String oldId;
  final String newId;
  final String? oldDir;
  final String newDir;
  final tasks = <_TaskPlan>[];
  Map<String, Object?> json = {};

  /// old absolute -> new absolute, files only.
  final fileMoves = <String, String>{};
  final dirMoves = <String, String>{};
}

class _TaskPlan {
  _TaskPlan({required this.oldId, required this.uid, required this.dir, required this.legacy});
  final String oldId;
  final String uid;
  final String dir;
  final Map<String, Object?> legacy;
  Map<String, Object?> json = {};
}

final _pathToken = RegExp(
  r'(?:\.\./|\./)?(?:[\w.\-]+/)*[\w.\-]+\.(?:md|txt|pdf|odt|ods|docx|doc|xlsx|json|csv|eml|html|png|jpg|jpeg)\b'
  r'|(?:\.\./|\./)?(?:[\w.\-]+/)+(?=[\s,;:.)`"\]]|$)',
);

/// Plans and (unless [dryRun]) applies the migration of [agendaDir].
Future<MigrationReport> migrateLegacy({
  required String agendaDir,
  bool dryRun = false,
  DateTime? now,
  Random? rng,
  Map<String, List<String>> sourceFolders = defaultSourceFolders,
  void Function(String)? log,
}) async {
  final r = MigrationReport();
  void say(String s) {
    r.log.add(s);
    log?.call(s);
  }

  final when = now ?? DateTime.now();
  agendaDir = normalizePath(Directory(agendaDir).absolute.path);
  final workspace = normalizePath('$agendaDir/..');

  // ---- phase A: read and plan ----------------------------------------------------
  final tasksFile = File('$agendaDir/tasks.json');
  if (!await tasksFile.exists()) throw StateError('no tasks.json in $agendaDir; nothing to migrate');
  final legacy = jsonDecode(await tasksFile.readAsString());
  if (legacy is! Map<String, Object?>) throw StateError('tasks.json is not a JSON object');

  final projectsDir = Directory('$agendaDir/projects');
  if (await projectsDir.exists()) {
    await for (final e in projectsDir.list()) {
      if (e is Directory && await File('${e.path}/project.json').exists()) {
        throw StateError('${e.path} already has a project.json; refusing to migrate twice');
      }
    }
  }

  var threads = <Map<String, Object?>>[];
  final threadsFile = File('$agendaDir/threads.json');
  if (await threadsFile.exists()) {
    final tj = jsonDecode(await threadsFile.readAsString());
    if (tj is Map<String, Object?>) threads = listOfMaps(tj['threads']);
  }

  final taken = <String>{};
  final plans = <_ProjectPlan>[];
  final uidOf = <String, String>{}; // oldPid/oldTid -> uid

  for (final pj in listOfMaps(legacy['projects'])) {
    final oldId = '${pj['id'] ?? ''}';
    final folder = pj['folder'] as String?;
    final oldDir = folder == null ? null : normalizePath('$agendaDir/$folder');
    final newId = oldDir == null ? oldId : oldDir.split('/').last;
    if (!isValidProjectId(newId)) throw StateError('project "$oldId": folder name "$newId" is not a valid project id');
    if (oldDir != null) {
      final type = await FileSystemEntity.type(oldDir, followLinks: false);
      if (type == FileSystemEntityType.notFound) throw StateError('project "$oldId": folder $oldDir does not exist');
      if (type != FileSystemEntityType.directory) throw StateError('project "$oldId": $oldDir is not a plain directory');
    }
    final newDir = '$agendaDir/projects/$newId';
    if (await Directory(newDir).exists()) throw StateError('$newDir already exists');
    final plan = _ProjectPlan(oldId: oldId, newId: newId, oldDir: oldDir, newDir: newDir);
    plans.add(plan);
    r.idMap['project:$oldId'] = newId;

    for (final tj in listOfMaps(pj['tasks'])) {
      final oldTid = '${tj['id'] ?? ''}';
      final uid = generateUid(taken, rng: rng);
      taken.add(uid);
      final name = '${tj['title'] ?? tj['name'] ?? oldTid}';
      final t = _TaskPlan(oldId: oldTid, uid: uid, dir: '$newDir/${taskFolderName(uid, name)}', legacy: tj);
      plan.tasks.add(t);
      uidOf['$oldId/$oldTid'] = uid;
      r.idMap['$oldId/$oldTid'] = uid;
      r.taskCount++;
    }
  }

  // Content moves per project.
  for (final plan in plans) {
    final oldDir = plan.oldDir;
    final sources = sourceFolders[plan.newId] ?? const <String>[];
    bool underSources(String rel) => sources.any((s) => rel == s || rel.startsWith('$s/'));

    // Files listed under a task move into that task's folder (first task wins).
    if (oldDir != null) {
      for (final t in plan.tasks) {
        for (final f in listOfMaps(t.legacy['files'])) {
          final abs = normalizePath('$agendaDir/${f['path']}');
          if (!abs.startsWith('$oldDir/') || plan.fileMoves.containsKey(abs)) continue;
          if (await File(abs).exists()) plan.fileMoves[abs] = '${t.dir}/${abs.split('/').last}';
        }
      }
      await for (final e in Directory(oldDir).list(recursive: true, followLinks: false)) {
        final rel = e.path.substring(oldDir.length + 1);
        final target = underSources(rel) ? '${plan.newDir}/sources/$rel' : '${plan.newDir}/data/$rel';
        if (e is Directory) {
          plan.dirMoves[e.path] = target;
        } else if (e is File || e is Link) {
          plan.fileMoves.putIfAbsent(e.path, () => target);
        }
      }
      r.moves.addAll(plan.fileMoves);
      r.moves.addAll(plan.dirMoves);
    }
  }

  String newPathOf(String abs) {
    for (final plan in plans) {
      final m = plan.fileMoves[abs] ?? plan.dirMoves[abs];
      if (m != null) return m;
    }
    return abs;
  }

  // Build the JSON documents.
  final legacyProjects = listOfMaps(legacy['projects']);
  final legacyDeadlines = listOfMaps(legacy['deadlines']);
  final usedThreads = <int>{};
  List<Map<String, Object?>> threadsFor(String node) {
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < threads.length; i++) {
      if (threads[i]['node'] == node) {
        usedThreads.add(i);
        out.add({...threads[i]}..remove('node'));
      }
    }
    return out;
  }

  for (var pi = 0; pi < plans.length; pi++) {
    final plan = plans[pi];
    final pj = legacyProjects[pi];
    String? earliest;
    for (final t in plan.tasks) {
      final history = listOfMaps(t.legacy['history']);
      final first = history.isEmpty ? null : '${history.first['date']}';
      final created = first != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(first)
          ? '${first}T00:00:00'
          : when.toIso8601String();
      if (earliest == null || created.compareTo(earliest) < 0) earliest = created;
      final files = <Map<String, Object?>>[];
      for (final f in listOfMaps(t.legacy['files'])) {
        final abs = normalizePath('$agendaDir/${f['path']}');
        files.add({...f, 'path': relativeTo(t.dir, newPathOf(abs))});
      }
      t.json = {
        'version': 1,
        'uid': t.uid,
        'name': '${t.legacy['title'] ?? t.legacy['name'] ?? t.oldId}',
        'status': TaskStatus.parse(t.legacy['status']).id,
        'priority': (t.legacy['priority'] as num?)?.toInt() ?? 3,
        'created': created,
        'due': t.legacy['due'],
        'next_step': t.legacy['next_step'],
        'waiting_on': t.legacy['waiting_on'],
        'watch': listOfMaps(t.legacy['watch']),
        'items': <Object?>[],
        'history': history,
        'files': files,
        'conversation': <Object?>[],
        'threads': threadsFor('task:${plan.oldId}/${t.oldId}'),
        'legacy_id': t.oldId,
      };
    }
    final docs = <String>[];
    for (final d in [if (pj['docs'] case final List<Object?> l) for (final x in l) '$x']) {
      final abs = normalizePath('$agendaDir/$d');
      final moved = newPathOf(abs);
      if (moved != abs) {
        docs.add(relativeTo(plan.newDir, moved));
      } else {
        docs.add(d);
        r.warnings.add('project ${plan.newId}: doc "$d" is outside the project folder, kept as is');
      }
    }
    final deadlines = <Map<String, Object?>>[];
    for (final d in legacyDeadlines) {
      if (d['project'] != plan.oldId) continue;
      String? uid;
      if (d['task'] != null) {
        uid = uidOf['${plan.oldId}/${d['task']}'];
        if (uid == null) r.warnings.add('deadline "${d['text']}": task ${d['task']} not found, link dropped');
      }
      deadlines.add({'date': d['date'], 'text': d['text'], 'task': uid});
    }
    plan.json = {
      'version': 1,
      'id': plan.newId,
      'title': '${pj['title'] ?? plan.newId}',
      'created': earliest ?? when.toIso8601String(),
      'status': pj['status'],
      'docs': docs,
      'deadlines': deadlines,
      'conversation': <Object?>[],
      'threads': threadsFor('project:${plan.oldId}'),
    };
  }
  for (final d in legacyDeadlines) {
    if (d['project'] == null || !plans.any((p) => p.oldId == d['project'])) {
      r.warnings.add('deadline "${d['text']}" (${d['date']}): no known project, dropped');
    }
  }
  final generalThreads = threadsFor('general');
  for (var i = 0; i < threads.length; i++) {
    if (usedThreads.contains(i)) continue;
    final t = {...threads[i]};
    final node = t.remove('node');
    t['archived'] = true;
    t['archived_at'] ??= when.toIso8601String();
    t['archived_reason'] = 'orphan from $node: ${t['archived_reason'] ?? 'its task no longer exists'}';
    generalThreads.add(t);
    r.warnings.add('thread ${t['id']} of $node has no target; kept in general.json as archived');
  }
  final generalJson = {'version': 1, 'conversation': <Object?>[], 'threads': generalThreads};

  // ---- report the plan ----------------------------------------------------------
  say('Projects:');
  for (final plan in plans) {
    say('  ${plan.oldId} -> projects/${plan.newId}/ (${plan.tasks.length} tasks${plan.oldDir == null ? '' : ', from ${plan.oldDir}'})');
    for (final t in plan.tasks) {
      say('    ${t.oldId.padRight(8)} -> ${t.uid}  ${t.dir.split('/').last}');
    }
  }
  say('Moves: ${r.moves.length} (files and folders)');
  for (final e in r.moves.entries) {
    say('  ${relativeTo(workspace, e.key)} -> ${relativeTo(workspace, e.value)}');
  }
  for (final w in r.warnings) {
    say('warning: $w');
  }
  if (dryRun) {
    say('Dry run: nothing changed.');
    return r;
  }

  // ---- phase B: apply --------------------------------------------------------------
  for (final plan in plans) {
    await Directory('${plan.newDir}/sources').create(recursive: true);
    await Directory('${plan.newDir}/data').create(recursive: true);
    for (final t in plan.tasks) {
      await Directory(t.dir).create(recursive: true);
    }
    for (final d in plan.dirMoves.values) {
      await Directory(d).create(recursive: true);
    }
    for (final e in plan.fileMoves.entries) {
      await Directory(e.value).parent.create(recursive: true);
      await File(e.key).rename(e.value);
    }
    final oldDir = plan.oldDir;
    if (oldDir != null) {
      final left = await Directory(oldDir).list(recursive: true).where((e) => e is! Directory).toList();
      if (left.isNotEmpty) throw StateError('$oldDir still has files after the move: ${left.first.path}');
      await Directory(oldDir).delete(recursive: true);
      final target = oldDir.startsWith('$workspace/')
          ? relativeTo(normalizePath('$oldDir/..'), plan.newDir)
          : plan.newDir;
      await Link(oldDir).create(target);
      say('symlink $oldDir -> $target');
    }
    await writeAtomic('${plan.newDir}/project.json', encodeJson(plan.json));
    for (final t in plan.tasks) {
      await writeAtomic('${t.dir}/task.json', encodeJson(t.json));
    }
  }
  await writeAtomic('$agendaDir/general.json', encodeJson(generalJson));

  final legacyDir = '$agendaDir/legacy';
  await Directory(legacyDir).create(recursive: true);
  for (final name in ['tasks.json', 'threads.json', 'next.md']) {
    final f = File('$agendaDir/$name');
    if (await f.exists()) await f.rename('$legacyDir/$name');
  }
  await writeAtomic(
    '$legacyDir/id-map.json',
    encodeJson({
      'migrated': when.toIso8601String(),
      'projects': {for (final p in plans) p.oldId: p.newId},
      'tasks': {
        for (final p in plans)
          for (final t in p.tasks) '${p.oldId}/${t.oldId}': {'uid': t.uid, 'folder': relativeTo(agendaDir, t.dir)},
      },
    }),
  );

  // Rewrite links inside the moved Markdown files.
  for (final plan in plans) {
    for (final e in plan.fileMoves.entries) {
      if (!e.value.toLowerCase().endsWith('.md')) continue;
      await _rewriteLinks(e.key, e.value, newPathOf, r);
    }
  }
  for (final l in r.unmappedLinks) {
    say('unmapped link: $l');
  }
  say('Done: ${plans.length} projects, ${r.taskCount} tasks. Old files under legacy/, id map in legacy/id-map.json.');
  r.applied = true;
  return r;
}

Future<void> _rewriteLinks(String oldPath, String newPath, String Function(String) newPathOf, MigrationReport r) async {
  final f = File(newPath);
  final text = await f.readAsString();
  final oldDir = normalizePath('$oldPath/..');
  final newDir = normalizePath('$newPath/..');
  var changed = false;
  final out = text.replaceAllMapped(_pathToken, (m) {
    final token = m.group(0)!;
    if (token.startsWith('/') || token.contains('://')) return token;
    final segments = token.split('/');
    // "www.example.de/" and the like are not paths.
    if (segments.sublist(0, segments.length - 1).any((s) => s.contains('.') && s != '..' && s != '.')) return token;
    final isDir = token.endsWith('/');
    final abs = normalizePath('$oldDir/$token');
    final moved = newPathOf(abs);
    if (moved != abs) {
      changed = true;
      final rel = relativeTo(newDir, moved);
      return isDir ? '$rel/' : rel;
    }
    if (FileSystemEntity.typeSync(normalizePath('$newDir/$token')) == FileSystemEntityType.notFound &&
        FileSystemEntity.typeSync(abs) == FileSystemEntityType.notFound) {
      r.unmappedLinks.add('${relativeTo(normalizePath('$newDir/../../..'), newPath)}: $token');
    }
    return token;
  });
  if (changed) await writeAtomic(newPath, out);
}
