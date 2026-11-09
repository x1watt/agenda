/// Loading the agenda from disk and the atomic per-file writers.
library;

import 'dart:convert';
import 'dart:io';

import 'ids.dart';
import 'model.dart';
import 'paths.dart';

const _encoder = JsonEncoder.withIndent('  ');

String encodeJson(Map<String, Object?> j) => '${_encoder.convert(j)}\n';

Map<String, Object?> _readJsonMap(String text, String what) {
  final Object? j;
  try {
    j = jsonDecode(text);
  } on FormatException catch (e) {
    throw FormatException('$what is not valid JSON: ${e.message}');
  }
  if (j is! Map<String, Object?>) throw FormatException('$what must be a JSON object');
  return j;
}

/// Reads projects/*/project.json, every task folder and general.json. Content
/// problems land in [Agenda.errors]; only a missing projects/ folder throws.
Future<Agenda> loadAgenda(String agendaDir) async {
  final projectsDir = '$agendaDir/projects';
  if (!await Directory(projectsDir).exists()) {
    throw FileSystemException('no projects folder (not migrated yet?)', projectsDir);
  }
  final errors = <String>[];
  final projects = <Project>[];
  final uids = <String, String>{};

  final dirs = [
    await for (final e in Directory(projectsDir).list())
      if (e is Directory) e,
  ]..sort((a, b) => a.path.compareTo(b.path));

  for (final pd in dirs) {
    final id = pd.path.split('/').last;
    if (!isValidProjectId(id)) {
      errors.add('${pd.path}: project folder name must match [A-Za-z0-9-]');
      continue;
    }
    final pf = File('${pd.path}/project.json');
    if (!await pf.exists()) continue; // a stray folder, not a project
    final Map<String, Object?> pj;
    try {
      pj = _readJsonMap(await pf.readAsString(), pf.path);
    } on FormatException catch (e) {
      errors.add(e.message);
      continue;
    } on FileSystemException catch (e) {
      errors.add('${pf.path}: ${e.message}');
      continue;
    }
    if (pj['id'] != null && pj['id'] != id) errors.add('${pf.path}: id "${pj['id']}" differs from the folder name');
    pj['id'] = id;

    final tasks = <AgendaTask>[];
    final taskDirs = [
      await for (final e in pd.list())
        if (e is Directory && uidOfFolder(e.path.split('/').last) != null) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    for (final td in taskDirs) {
      final folderUid = uidOfFolder(td.path.split('/').last)!;
      final tf = File('${td.path}/task.json');
      if (!await tf.exists()) {
        errors.add('${td.path}: no task.json');
        continue;
      }
      final Map<String, Object?> tj;
      try {
        tj = _readJsonMap(await tf.readAsString(), tf.path);
      } on FormatException catch (e) {
        errors.add(e.message);
        continue;
      } on FileSystemException catch (e) {
        errors.add('${tf.path}: ${e.message}');
        continue;
      }
      if (tj['uid'] != folderUid) {
        errors.add('${tf.path}: uid "${tj['uid']}" differs from the folder name');
        continue;
      }
      if (uids.containsKey(folderUid)) {
        errors.add('${tf.path}: duplicate uid $folderUid (also ${uids[folderUid]})');
        continue;
      }
      uids[folderUid] = tf.path;
      tasks.add(AgendaTask.fromJson(tj, dir: td.path, projectId: id));
    }
    projects.add(Project.fromJson(pj, dir: pd.path, tasks: tasks));
  }

  final generalPath = '$agendaDir/general.json';
  var general = GeneralTopic(path: generalPath);
  final gf = File(generalPath);
  if (await gf.exists()) {
    try {
      general = GeneralTopic.fromJson(_readJsonMap(await gf.readAsString(), generalPath), path: generalPath);
    } on FormatException catch (e) {
      errors.add(e.message);
    }
  }
  final eventsPath = '$agendaDir/events.json';
  var events = <AgendaEvent>[];
  final ef = File(eventsPath);
  if (await ef.exists()) {
    try {
      final ej = _readJsonMap(await ef.readAsString(), eventsPath);
      for (final m in validateEventsJson(ej)) {
        errors.add('$eventsPath: $m');
      }
      events = listOfMaps(ej['events']).map(AgendaEvent.fromJson).where((e) => e.day != null).toList()
        ..sort((a, b) => '${a.date}${a.time ?? ''}'.compareTo('${b.date}${b.time ?? ''}'));
    } on FormatException catch (e) {
      errors.add(e.message);
    }
  }
  final recurringPath = '$agendaDir/recurring.json';
  var recurringTopics = <RecurringTopic>[];
  final rf = File(recurringPath);
  if (await rf.exists()) {
    try {
      final rj = _readJsonMap(await rf.readAsString(), recurringPath);
      for (final m in validateRecurringJson(rj)) {
        errors.add('$recurringPath: $m');
      }
      recurringTopics = listOfMaps(rj['topics']).map(RecurringTopic.fromJson).toList();
    } on FormatException catch (e) {
      errors.add(e.message);
    }
  }
  return Agenda(
    dir: agendaDir,
    projects: projects,
    general: general,
    events: events,
    recurringTopics: recurringTopics,
    errors: errors,
  );
}

// ---- writers ------------------------------------------------------------------

final _chains = <String, Future<void>>{};

/// Read, edit, atomic write of one JSON file, keeping fields the model does not
/// know about. Writes to the same path are serialised. Returns false if the
/// file is missing or not an object.
Future<bool> updateJsonFile(String path, void Function(Map<String, Object?> j) edit) {
  final prev = _chains[path] ?? Future<void>.value();
  final next = prev.then((_) => _updateNow(path, edit));
  _chains[path] = next.then((_) {}, onError: (_) {});
  return next;
}

Future<bool> _updateNow(String path, void Function(Map<String, Object?> j) edit) async {
  final f = File(path);
  if (!await f.exists()) return false;
  final j = jsonDecode(await f.readAsString());
  if (j is! Map<String, Object?>) return false;
  edit(j);
  await writeAtomic(path, encodeJson(j));
  return true;
}

List<Object?> _list(Map<String, Object?> j, String key) {
  final v = j[key];
  if (v is List<Object?>) return v;
  final fresh = <Object?>[];
  j[key] = fresh;
  return fresh;
}

Future<bool> updateTask(AgendaTask t, void Function(Map<String, Object?> j) edit) =>
    updateJsonFile(t.jsonPath, edit);

Future<bool> updateProject(Project p, void Function(Map<String, Object?> j) edit) =>
    updateJsonFile(p.jsonPath, edit);

/// Creates general.json if needed, then edits it.
Future<bool> updateGeneral(String agendaDir, void Function(Map<String, Object?> j) edit) async {
  final path = '$agendaDir/general.json';
  if (!await File(path).exists()) {
    await writeAtomic(path, encodeJson(GeneralTopic().toJson()));
  }
  return updateJsonFile(path, edit);
}

/// Edits the file behind a node (`general`, `project:<id>`, `task:<uid>`).
Future<bool> updateNode(Agenda agenda, String node, void Function(Map<String, Object?> j) edit) {
  if (node == 'general') return updateGeneral(agenda.dir, edit);
  final path = agenda.jsonPathForNode(node);
  return path == null ? Future.value(false) : updateJsonFile(path, edit);
}

Future<bool> appendHistory(String jsonPath, String text, {String? date}) =>
    updateJsonFile(jsonPath, (j) => _list(j, 'history').add({'date': date ?? todayIso(), 'text': text}));

Future<bool> appendConversation(String jsonPath, ConversationEntry e) =>
    updateJsonFile(jsonPath, (j) => _list(j, 'conversation').add(e.toJson()));

Future<bool> addThread(String jsonPath, ThreadInfo t) =>
    updateJsonFile(jsonPath, (j) => _list(j, 'threads').add(t.toJson()));

Map<String, Object?>? _thread(Map<String, Object?> j, String id) =>
    _list(j, 'threads').whereType<Map<String, Object?>>().where((t) => t['id'] == id).firstOrNull;

void _archiveIn(Map<String, Object?> t, String reason) {
  t['archived'] = true;
  t['archived_at'] = nowIso();
  t['archived_reason'] = reason;
}

Future<bool> archiveThread(String jsonPath, String id, String reason) => updateJsonFile(jsonPath, (j) {
      final t = _thread(j, id);
      if (t != null && t['archived'] != true) _archiveIn(t, reason);
    });

/// Unarchives thread [id]. Threads run in parallel, so the others stay as they are.
Future<bool> restoreThread(String jsonPath, String id) => updateJsonFile(jsonPath, (j) {
      final t = _thread(j, id);
      if (t == null) return;
      t['archived'] = false;
      t['archived_at'] = null;
      t['archived_reason'] = null;
    });

Future<bool> setTaskStatus(AgendaTask t, TaskStatus s, {String source = 'the agenda app'}) =>
    updateTask(t, (j) {
      j['status'] = s.id;
      _list(j, 'history').add({'date': todayIso(), 'text': 'Status set to "${s.label}" in $source'});
    });

/// Sets the review status of [relPath] (relative to the task folder), adding it to files[].
Future<bool> setFileStatus(AgendaTask t, String relPath, String status, {bool history = true}) =>
    updateTask(t, (j) {
      final files = _list(j, 'files');
      files.removeWhere((m) => m is Map && m['path'] == relPath);
      files.add({'path': relPath, 'status': status, 'at': nowIso()});
      if (history) {
        final what = status == 'approved' ? 'approved' : 'marked $status';
        _list(j, 'history').add({'date': todayIso(), 'text': 'User $what $relPath in the agenda app'});
      }
    });

Future<bool> setItemDone(AgendaTask t, String itemId, bool done) => updateTask(t, (j) {
      for (final i in _list(j, 'items').whereType<Map<String, Object?>>()) {
        if (i['id'] != itemId) continue;
        i['done'] = done;
        i['done_at'] = done ? nowIso() : null;
        _list(j, 'history').add({
          'date': todayIso(),
          'text': '${done ? 'Ticked' : 'Unticked'} item ${i['id']} "${i['text']}" in the agenda app',
        });
      }
    });

/// Appends an item and returns its id.
Future<String?> addItem(AgendaTask t, String text, {String? due}) async {
  String? id;
  final ok = await updateTask(t, (j) {
    final items = _list(j, 'items');
    var max = 0;
    for (final i in items.whereType<Map<String, Object?>>()) {
      max = [max, int.tryParse('${i['id']}') ?? 0].reduce((a, b) => a > b ? a : b);
    }
    id = '${max + 1}';
    items.add({'id': id, 'text': text, 'done': false, 'done_at': null, 'due': due});
  });
  return ok ? id : null;
}

/// Makes projects/<id>/ with project.json, sources/ and data/.
Future<Project> createProject({
  required String agendaDir,
  required String id,
  required String title,
  DateTime? now,
}) async {
  if (!isValidProjectId(id)) throw ArgumentError('project id "$id" must match [A-Za-z0-9-]');
  final dir = '$agendaDir/projects/$id';
  if (await File('$dir/project.json').exists()) throw StateError('project "$id" already exists');
  await Directory('$dir/sources').create(recursive: true);
  await Directory('$dir/data').create(recursive: true);
  final p = Project(id: id, title: title, created: (now ?? DateTime.now()).toIso8601String(), dir: dir);
  await writeAtomic(p.jsonPath, encodeJson(p.toJson()));
  return p;
}

/// Makes <project>/<UID>-<slug>/task.json with a fresh UID.
Future<AgendaTask> createTask({
  required Project project,
  required String name,
  TaskStatus status = TaskStatus.todo,
  int priority = 3,
  String? due,
  String? scheduled,
  String? nextStep,
  DateTime? now,
  Set<String>? taken,
  String? follows,
  List<Item> items = const [],
  List<Watch> watch = const [],
}) async {
  final projectsDir = Directory(project.dir).parent.path;
  final uid = generateUid(taken ?? await takenUids(projectsDir));
  final dir = '${project.dir}/${taskFolderName(uid, name)}';
  await Directory(dir).create(recursive: true);
  final t = AgendaTask(
    uid: uid,
    name: name,
    status: status,
    priority: priority,
    created: (now ?? DateTime.now()).toIso8601String(),
    due: due,
    scheduled: scheduled,
    nextStep: nextStep,
    follows: follows,
    items: [for (final i in items) Item(id: i.id, text: i.text, due: i.due)],
    watch: watch,
    dir: dir,
    projectId: project.id,
  );
  await writeAtomic(t.jsonPath, encodeJson(t.toJson()));
  return t;
}

// ---- validation -----------------------------------------------------------------

const _statuses = ['todo', 'in_progress', 'waiting', 'needs_user', 'done', 'cancelled'];
final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _isoDateTime = RegExp(r'^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$');
final _hhmm = RegExp(r'^\d{2}:\d{2}$');

/// Problems with a task.json object (empty when fine).
List<String> validateTaskJson(Map<String, Object?> j) {
  final out = <String>[];
  if (j['uid'] is! String || !isValidUid(j['uid'] as String)) out.add('uid must be XXX-XXX');
  if ('${j['name'] ?? ''}'.trim().isEmpty) out.add('name is empty');
  if (!_statuses.contains(j['status'])) out.add('status "${j['status']}" is not one of ${_statuses.join(', ')}');
  if (j['due'] != null && !_isoDate.hasMatch('${j['due']}')) out.add('due must be YYYY-MM-DD');
  if (j['scheduled'] != null && !_isoDateTime.hasMatch('${j['scheduled']}')) out.add('scheduled must be YYYY-MM-DD or YYYY-MM-DDTHH:MM');
  if (j['follows'] != null && !isValidUid('${j['follows']}')) out.add('follows must be a UID');
  for (final k in ['watch', 'items', 'history', 'files', 'conversation', 'threads']) {
    if (j[k] != null && j[k] is! List) out.add('$k must be a list');
  }
  for (final h in listOfMaps(j['history'])) {
    if (!_isoDate.hasMatch('${h['date']}')) out.add('history date "${h['date']}" must be YYYY-MM-DD');
  }
  final ids = <String>{};
  for (final i in listOfMaps(j['items'])) {
    if (!ids.add('${i['id']}')) out.add('duplicate item id ${i['id']}');
  }
  for (final f in listOfMaps(j['files'])) {
    if (f['status'] != 'needs_review' && f['status'] != 'approved') out.add('file ${f['path']}: status must be needs_review or approved');
  }
  return out;
}

List<String> validateProjectJson(Map<String, Object?> j) {
  final out = <String>[];
  if (j['id'] is! String || !isValidProjectId(j['id'] as String)) out.add('id must match [A-Za-z0-9-]');
  if ('${j['title'] ?? ''}'.trim().isEmpty) out.add('title is empty');
  for (final k in ['docs', 'deadlines', 'conversation', 'threads']) {
    if (j[k] != null && j[k] is! List) out.add('$k must be a list');
  }
  for (final d in listOfMaps(j['deadlines'])) {
    if (!_isoDate.hasMatch('${d['date']}')) out.add('deadline date "${d['date']}" must be YYYY-MM-DD');
    if (d['task'] != null && !isValidUid('${d['task']}')) out.add('deadline task "${d['task']}" is not a UID');
  }
  return out;
}

// ---- editing ----------------------------------------------------------------------

/// Changes plain task fields (`name`, `due`, `scheduled`, `priority`, `next_step`, `waiting_on`)
/// and appends one history line naming what changed.
Future<bool> editTaskFields(AgendaTask t, Map<String, Object?> changes, {String source = 'the agenda app'}) {
  const allowed = {'name', 'due', 'scheduled', 'priority', 'next_step', 'waiting_on'};
  final bad = changes.keys.where((k) => !allowed.contains(k));
  if (bad.isNotEmpty) throw ArgumentError('cannot edit ${bad.join(', ')} this way');
  return updateTask(t, (j) {
    final changed = <String>[];
    changes.forEach((k, v) {
      if (j[k] == v) return;
      j[k] = v;
      changed.add(k == 'name' ? 'name to "$v"' : '$k to ${v ?? '-'}');
    });
    if (changed.isNotEmpty) {
      _list(j, 'history').add({'date': todayIso(), 'text': 'Changed ${changed.join(', ')} in $source'});
    }
  });
}

Future<bool> removeItem(AgendaTask t, String itemId) => updateTask(t, (j) {
      final items = _list(j, 'items');
      final gone = items.whereType<Map<String, Object?>>().where((i) => i['id'] == itemId).firstOrNull;
      if (gone == null) return;
      items.remove(gone);
      _list(j, 'history').add({'date': todayIso(), 'text': 'Removed item $itemId "${gone['text']}" in the agenda app'});
    });

/// Creates a task in the same project that continues [from]: `follows` points at
/// it, open items move over when [moveOpenItems], and both histories say so.
Future<AgendaTask> spawnFollowUp({
  required Project project,
  required AgendaTask from,
  required String name,
  bool moveOpenItems = false,
  String? nextStep,
  String? due,
  DateTime? now,
}) async {
  final open = [for (final i in from.items) if (!i.done) i];
  final t = await createTask(
    project: project,
    name: name,
    priority: from.priority,
    due: due,
    nextStep: nextStep,
    now: now,
    follows: from.uid,
    items: moveOpenItems ? open : const [],
    watch: from.watch,
  );
  await updateTask(t, (j) => _list(j, 'history').add({
        'date': todayIso(),
        'text': 'Created as a follow-up of ${from.uid} "${from.name}"${moveOpenItems && open.isNotEmpty ? ', ${open.length} open items moved here' : ''}',
      }));
  await updateTask(from, (j) {
    if (moveOpenItems && open.isNotEmpty) {
      final gone = open.map((i) => i.id).toSet();
      _list(j, 'items').removeWhere((i) => i is Map && gone.contains('${i['id']}'));
    }
    _list(j, 'history').add({
      'date': todayIso(),
      'text': 'Follow-up ${t.uid} "$name" created${moveOpenItems && open.isNotEmpty ? ', ${open.length} open items moved there' : ''}',
    });
  });
  return t;
}

// ---- events -------------------------------------------------------------------------

/// Problems with an events.json object (empty when fine).
List<String> validateEventsJson(Map<String, Object?> j) {
  final out = <String>[];
  if (j['events'] != null && j['events'] is! List) return ['events must be a list'];
  final ids = <String>{};
  for (final e in listOfMaps(j['events'])) {
    final id = '${e['id'] ?? ''}';
    if (id.isEmpty) out.add('an event has no id');
    if (!ids.add(id)) out.add('duplicate event id $id');
    if (!_isoDate.hasMatch('${e['date']}')) out.add('event $id: date must be YYYY-MM-DD');
    if ('${e['title'] ?? ''}'.trim().isEmpty) out.add('event $id: title is empty');
    for (final k in ['time', 'end']) {
      if (e[k] != null && !_hhmm.hasMatch('${e[k]}')) out.add('event $id: $k must be HH:MM');
    }
    if (e['task'] != null && !isValidUid('${e['task']}')) out.add('event $id: task must be a UID');
  }
  return out;
}

Future<bool> _updateEvents(String agendaDir, void Function(List<Object?> events) edit) async {
  final path = '$agendaDir/events.json';
  if (!await File(path).exists()) {
    await writeAtomic(path, encodeJson({'version': 1, 'events': <Object?>[]}));
  }
  return updateJsonFile(path, (j) => edit(_list(j, 'events')));
}

/// Adds [e] to events.json (created when missing). An empty id gets a fresh one.
Future<AgendaEvent> addEvent(String agendaDir, AgendaEvent e) async {
  final id = e.id.isNotEmpty ? e.id : 'e${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
  final stored = AgendaEvent.fromJson({...e.toJson(), 'id': id});
  await _updateEvents(agendaDir, (list) => list.add(stored.toJson()));
  return stored;
}

/// Replaces the event with the same id.
Future<bool> updateEvent(String agendaDir, AgendaEvent e) => _updateEvents(agendaDir, (list) {
      final i = list.indexWhere((x) => x is Map && x['id'] == e.id);
      if (i >= 0) list[i] = e.toJson();
    });

Future<bool> removeEvent(String agendaDir, String id) =>
    _updateEvents(agendaDir, (list) => list.removeWhere((x) => x is Map && x['id'] == id));

// ---- recurring ----------------------------------------------------------------------

const _recurringIntervals = {'yearly', 'monthly', 'days'};

/// Problems with a recurring.json object (empty when fine).
List<String> validateRecurringJson(Map<String, Object?> j) {
  final out = <String>[];
  if (j['topics'] != null && j['topics'] is! List) return ['topics must be a list'];
  final topicIds = <String>{};
  final itemIds = <String>{};
  for (final t in listOfMaps(j['topics'])) {
    final topicId = '${t['id'] ?? ''}';
    if (topicId.isEmpty) out.add('a topic has no id');
    if (!topicIds.add(topicId)) out.add('duplicate topic id $topicId');
    if ('${t['title'] ?? ''}'.trim().isEmpty) out.add('topic $topicId: title is empty');
    if (t['items'] != null && t['items'] is! List) {
      out.add('topic $topicId: items must be a list');
      continue;
    }
    for (final i in listOfMaps(t['items'])) {
      final id = '${i['id'] ?? ''}';
      if (id.isEmpty) out.add('topic $topicId: an item has no id');
      if (!itemIds.add(id)) out.add('duplicate recurring item id $id');
      if ('${i['text'] ?? ''}'.trim().isEmpty) out.add('item $id: text is empty');
      if (!_recurringIntervals.contains(i['interval'])) out.add('item $id: interval must be yearly, monthly or days');
      final every = i['every'];
      if (every != null && (every is! num || every < 1)) out.add('item $id: every must be a positive number');
      if (!_isoDate.hasMatch('${i['anchor']}')) out.add('item $id: anchor must be YYYY-MM-DD');
      if (!_isoDate.hasMatch('${i['next_due']}')) out.add('item $id: next_due must be YYYY-MM-DD');
      if (i['task'] != null && !isValidUid('${i['task']}')) out.add('item $id: task must be a UID');
    }
  }
  return out;
}

Future<bool> _updateRecurring(String agendaDir, void Function(List<Object?> topics) edit) async {
  final path = '$agendaDir/recurring.json';
  if (!await File(path).exists()) {
    await writeAtomic(path, encodeJson({'version': 1, 'topics': <Object?>[]}));
  }
  return updateJsonFile(path, (j) => edit(_list(j, 'topics')));
}

List<Object?>? _topicItems(List<Object?> topics, String topicId) {
  for (final t in topics) {
    if (t is Map<String, Object?> && t['id'] == topicId) return _list(t, 'items');
  }
  return null;
}

/// Adds a topic to recurring.json (created when missing). An empty id gets
/// `slugFor(title)`, deduped with a numeric suffix on collision.
Future<RecurringTopic> addRecurringTopic(String agendaDir, String title, {String? id}) async {
  var topicId = id?.isNotEmpty == true ? id! : slugFor(title);
  await _updateRecurring(agendaDir, (topics) {
    final taken = {for (final t in topics) if (t is Map) '${t['id']}'};
    if (taken.contains(topicId)) {
      var n = 2;
      while (taken.contains('$topicId-$n')) {
        n++;
      }
      topicId = '$topicId-$n';
    }
    topics.add(RecurringTopic(id: topicId, title: title).toJson());
  });
  return RecurringTopic(id: topicId, title: title);
}

Future<bool> renameRecurringTopic(String agendaDir, String topicId, String title) =>
    _updateRecurring(agendaDir, (topics) {
      for (final t in topics) {
        if (t is Map<String, Object?> && t['id'] == topicId) t['title'] = title;
      }
    });

Future<bool> removeRecurringTopic(String agendaDir, String topicId) =>
    _updateRecurring(agendaDir, (topics) => topics.removeWhere((t) => t is Map && t['id'] == topicId));

/// Adds [item] under [topicId]. An empty id gets a fresh one.
Future<RecurringItem> addRecurringItem(String agendaDir, String topicId, RecurringItem item) async {
  final id = item.id.isNotEmpty ? item.id : 'r${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
  final stored = RecurringItem.fromJson({...item.toJson(), 'id': id});
  await _updateRecurring(agendaDir, (topics) {
    final items = _topicItems(topics, topicId);
    items?.add(stored.toJson());
  });
  return stored;
}

Future<bool> updateRecurringItem(String agendaDir, String topicId, RecurringItem item) =>
    _updateRecurring(agendaDir, (topics) {
      final items = _topicItems(topics, topicId);
      if (items == null) return;
      final i = items.indexWhere((x) => x is Map && x['id'] == item.id);
      if (i >= 0) items[i] = item.toJson();
    });

Future<bool> removeRecurringItem(String agendaDir, String topicId, String itemId) =>
    _updateRecurring(agendaDir, (topics) {
      final items = _topicItems(topics, topicId);
      items?.removeWhere((x) => x is Map && x['id'] == itemId);
    });

/// Marks the item done for this cycle: logs history and advances `next_due`
/// from its previous value (not from today), per [RecurringItem.nextOccurrenceAfter].
Future<bool> markRecurringItemDone(String agendaDir, String topicId, String itemId, {String? doneDate}) =>
    _updateRecurring(agendaDir, (topics) {
      final items = _topicItems(topics, topicId);
      if (items == null) return;
      final i = items.indexWhere((x) => x is Map && x['id'] == itemId);
      if (i < 0) return;
      final item = RecurringItem.fromJson(items[i] as Map<String, Object?>);
      final done = doneDate ?? todayIso();
      final next = item.nextOccurrenceAfter(item.nextDue);
      final updated = RecurringItem(
        id: item.id,
        text: item.text,
        interval: item.interval,
        every: item.every,
        anchor: item.anchor,
        nextDue: next,
        lastDone: done,
        note: item.note,
        project: item.project,
        task: item.task,
        history: [...item.history, HistoryEntry(date: done, text: 'Done, next due $next')],
      );
      items[i] = updated.toJson();
    });
