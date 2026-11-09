/// Data model of the agenda: projects/<id>/project.json, <UID>-<slug>/task.json,
/// general.json. See docs/format.md.
library;

/// Task lifecycle. `needsUser` means Claude cannot move it without the user.
enum TaskStatus {
  todo('todo', 'To do'),
  inProgress('in_progress', 'In progress'),
  waiting('waiting', 'Waiting'),
  needsUser('needs_user', 'Needs you'),
  done('done', 'Done'),
  cancelled('cancelled', 'Cancelled');

  const TaskStatus(this.id, this.label);
  final String id;
  final String label;

  bool get isOpen => this != done && this != cancelled;

  static TaskStatus parse(Object? s) =>
      values.firstWhere((v) => v.id == s, orElse: () => TaskStatus.todo);
}

class HistoryEntry {
  HistoryEntry({required this.date, required this.text});
  final String date;
  final String text;

  factory HistoryEntry.fromJson(Map<String, Object?> j) =>
      HistoryEntry(date: '${j['date'] ?? ''}', text: '${j['text'] ?? ''}');

  Map<String, Object?> toJson() => {'date': date, 'text': text};
}

/// A sender pattern the checker watches for (matched as IMAP FROM substring).
class Watch {
  Watch({required this.from});
  final String from;

  factory Watch.fromJson(Map<String, Object?> j) => Watch(from: '${j['from'] ?? ''}');
  Map<String, Object?> toJson() => {'from': from};
}

/// A file attached to a task for review. [path] is relative to the task folder.
class TaskFileRef {
  TaskFileRef({required this.path, this.status = 'needs_review', this.at});
  final String path;

  /// `needs_review` or `approved`.
  final String status;

  /// When the status was set (ISO timestamp).
  final String? at;

  bool get approved => status == 'approved';
  DateTime? get when => at == null ? null : DateTime.tryParse(at!);

  factory TaskFileRef.fromJson(Map<String, Object?> j) =>
      TaskFileRef(path: '${j['path'] ?? ''}', status: '${j['status'] ?? 'needs_review'}', at: j['at'] as String?);

  Map<String, Object?> toJson() => {'path': path, 'status': status, 'at': at};
}

/// One point of a task's checklist.
class Item {
  Item({required this.id, required this.text, this.done = false, this.doneAt, this.due});
  final String id;
  final String text;
  final bool done;
  final String? doneAt;
  final String? due;

  factory Item.fromJson(Map<String, Object?> j) => Item(
        id: '${j['id'] ?? ''}',
        text: '${j['text'] ?? ''}',
        done: j['done'] == true,
        doneAt: j['done_at'] as String?,
        due: j['due'] as String?,
      );

  Map<String, Object?> toJson() => {'id': id, 'text': text, 'done': done, 'done_at': doneAt, 'due': due};
}

/// One message of a stored chat.
class ConversationEntry {
  ConversationEntry({required this.at, required this.role, required this.text, this.session});
  final DateTime at;

  /// `user` or `assistant`.
  final String role;
  final String text;

  /// Claude session id the message belongs to, null if the session never started.
  final String? session;

  factory ConversationEntry.fromJson(Map<String, Object?> j) => ConversationEntry(
        at: DateTime.tryParse('${j['at'] ?? ''}') ?? DateTime(0),
        role: '${j['role'] ?? 'user'}',
        text: '${j['text'] ?? ''}',
        session: j['session'] as String?,
      );

  Map<String, Object?> toJson() =>
      {'at': at.toIso8601String(), 'role': role, 'text': text, 'session': session};
}

/// A Claude session about one node (task, project, general). Its id is the
/// Claude session id; the transcript lives with Claude Code.
class ThreadInfo {
  ThreadInfo({
    required this.id,
    required this.created,
    this.archived = false,
    this.archivedAt,
    this.archivedReason,
  });

  final String id;
  final DateTime created;
  final bool archived;
  final DateTime? archivedAt;
  final String? archivedReason;

  factory ThreadInfo.fromJson(Map<String, Object?> j) => ThreadInfo(
        id: '${j['id']}',
        created: DateTime.tryParse('${j['created'] ?? ''}') ?? DateTime(0),
        archived: j['archived'] == true,
        archivedAt: DateTime.tryParse('${j['archived_at'] ?? ''}'),
        archivedReason: j['archived_reason'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'created': created.toIso8601String(),
        'archived': archived,
        'archived_at': archivedAt?.toIso8601String(),
        'archived_reason': archivedReason,
      };
}

ThreadInfo? _activeThread(List<ThreadInfo> threads) {
  final open = threads.where((t) => !t.archived).toList()..sort((a, b) => a.created.compareTo(b.created));
  return open.lastOrNull;
}

/// A task: projects/<project>/<UID>-<slug>/task.json.
class AgendaTask {
  AgendaTask({
    required this.uid,
    required this.name,
    this.version = 1,
    this.status = TaskStatus.todo,
    this.priority = 3,
    this.created,
    this.due,
    this.scheduled,
    this.nextStep,
    this.waitingOn,
    this.watch = const [],
    this.items = const [],
    this.history = const [],
    this.files = const [],
    this.conversation = const [],
    this.threads = const [],
    this.legacyId,
    this.follows,
    this.dir = '',
    this.projectId = '',
  });

  final int version;
  final String uid;
  final String name;
  final TaskStatus status;
  final int priority;

  /// ISO timestamp of creation.
  final String? created;

  /// ISO date (YYYY-MM-DD) or null.
  final String? due;

  /// When the user plans to work on it: `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM`, or null.
  final String? scheduled;
  final String? nextStep;
  final String? waitingOn;
  final List<Watch> watch;
  final List<Item> items;
  final List<HistoryEntry> history;

  /// Files the user should review for this task (drafts, letters, forms).
  final List<TaskFileRef> files;
  final List<ConversationEntry> conversation;
  final List<ThreadInfo> threads;

  /// UID of the task this one continues (a follow-up), or null.
  final String? follows;

  /// The id in the old tasks.json (`T1`, `H1`), if migrated.
  final String? legacyId;

  /// Absolute task folder (set by the loader, not serialised).
  final String dir;

  /// Owning project id (set by the loader, not serialised).
  final String projectId;

  String get jsonPath => '$dir/task.json';
  String get folderName => dir.split('/').last;
  String get node => 'task:$uid';
  DateTime? get dueDate => due == null ? null : DateTime.tryParse(due!);
  DateTime? get scheduledAt => scheduled == null ? null : DateTime.tryParse(scheduled!);

  /// True when [scheduled] carries a time of day.
  bool get scheduledHasTime => scheduled != null && scheduled!.contains('T');
  DateTime? get createdAt => created == null ? null : DateTime.tryParse(created!);
  bool get isOpen => status.isOpen;
  ThreadInfo? get activeThread => _activeThread(threads);

  /// Date of the last history entry, or the creation date.
  String? get lastActivity => history.isEmpty ? created?.substring(0, 10) : history.last.date;

  factory AgendaTask.fromJson(Map<String, Object?> j, {String dir = '', String projectId = ''}) => AgendaTask(
        version: (j['version'] as num?)?.toInt() ?? 1,
        uid: '${j['uid'] ?? ''}',
        name: '${j['name'] ?? j['title'] ?? ''}',
        status: TaskStatus.parse(j['status']),
        priority: (j['priority'] as num?)?.toInt() ?? 3,
        created: j['created'] as String?,
        due: j['due'] as String?,
        scheduled: j['scheduled'] as String?,
        nextStep: j['next_step'] as String?,
        waitingOn: j['waiting_on'] as String?,
        watch: listOfMaps(j['watch']).map(Watch.fromJson).toList(),
        items: listOfMaps(j['items']).map(Item.fromJson).toList(),
        history: listOfMaps(j['history']).map(HistoryEntry.fromJson).toList(),
        files: listOfMaps(j['files']).map(TaskFileRef.fromJson).toList(),
        conversation: listOfMaps(j['conversation']).map(ConversationEntry.fromJson).toList(),
        threads: listOfMaps(j['threads']).map(ThreadInfo.fromJson).toList(),
        legacyId: j['legacy_id'] as String?,
        follows: j['follows'] as String?,
        dir: dir,
        projectId: projectId,
      );

  Map<String, Object?> toJson() => {
        'version': version,
        'uid': uid,
        'name': name,
        'status': status.id,
        'priority': priority,
        'created': created,
        'due': due,
        if (scheduled != null) 'scheduled': scheduled,
        'next_step': nextStep,
        'waiting_on': waitingOn,
        'watch': [for (final w in watch) w.toJson()],
        'items': [for (final i in items) i.toJson()],
        'history': [for (final h in history) h.toJson()],
        'files': [for (final f in files) f.toJson()],
        'conversation': [for (final c in conversation) c.toJson()],
        'threads': [for (final t in threads) t.toJson()],
        'follows': follows,
        if (legacyId != null) 'legacy_id': legacyId,
      };
}

/// A date that belongs to a project, optionally tied to a task.
class Deadline {
  Deadline({required this.date, required this.text, this.task, this.projectId});
  final String date;
  final String text;

  /// Task UID or null.
  final String? task;

  /// Set by the loader.
  final String? projectId;

  String? get project => projectId;
  DateTime? get when => DateTime.tryParse(date);

  factory Deadline.fromJson(Map<String, Object?> j, {String? projectId}) => Deadline(
        date: '${j['date'] ?? ''}',
        text: '${j['text'] ?? ''}',
        task: j['task'] as String?,
        projectId: projectId,
      );

  Map<String, Object?> toJson() => {'date': date, 'text': text, 'task': task};
}

/// A project: projects/<id>/project.json plus its task folders.
class Project {
  Project({
    required this.id,
    required this.title,
    this.version = 1,
    this.created,
    this.status,
    this.docs = const [],
    this.deadlines = const [],
    this.conversation = const [],
    this.threads = const [],
    this.dir = '',
    this.tasks = const [],
  });

  final int version;
  final String id;
  final String title;
  final String? created;

  /// One-line project status.
  final String? status;

  /// Relative to the project folder.
  final List<String> docs;
  final List<Deadline> deadlines;
  final List<ConversationEntry> conversation;
  final List<ThreadInfo> threads;

  /// Absolute project folder (set by the loader).
  final String dir;

  /// From the subfolders (set by the loader).
  final List<AgendaTask> tasks;

  String get jsonPath => '$dir/project.json';
  String get sourcesDir => '$dir/sources';
  String get dataDir => '$dir/data';
  String get node => 'project:$id';
  ThreadInfo? get activeThread => _activeThread(threads);

  factory Project.fromJson(Map<String, Object?> j, {String dir = '', List<AgendaTask> tasks = const []}) {
    final id = '${j['id'] ?? ''}';
    return Project(
      version: (j['version'] as num?)?.toInt() ?? 1,
      id: id,
      title: '${j['title'] ?? id}',
      created: j['created'] as String?,
      status: j['status'] as String?,
      docs: [if (j['docs'] case final List<Object?> d) for (final x in d) '$x'],
      deadlines: listOfMaps(j['deadlines']).map((m) => Deadline.fromJson(m, projectId: id)).toList(),
      conversation: listOfMaps(j['conversation']).map(ConversationEntry.fromJson).toList(),
      threads: listOfMaps(j['threads']).map(ThreadInfo.fromJson).toList(),
      dir: dir,
      tasks: tasks,
    );
  }

  Map<String, Object?> toJson() => {
        'version': version,
        'id': id,
        'title': title,
        'created': created,
        'status': status,
        'docs': docs,
        'deadlines': [for (final d in deadlines) d.toJson()],
        'conversation': [for (final c in conversation) c.toJson()],
        'threads': [for (final t in threads) t.toJson()],
      };
}

/// agenda/general.json: the General topic.
class GeneralTopic {
  GeneralTopic({this.version = 1, this.conversation = const [], this.threads = const [], this.path = ''});
  final int version;
  final List<ConversationEntry> conversation;
  final List<ThreadInfo> threads;
  final String path;

  ThreadInfo? get activeThread => _activeThread(threads);

  factory GeneralTopic.fromJson(Map<String, Object?> j, {String path = ''}) => GeneralTopic(
        version: (j['version'] as num?)?.toInt() ?? 1,
        conversation: listOfMaps(j['conversation']).map(ConversationEntry.fromJson).toList(),
        threads: listOfMaps(j['threads']).map(ThreadInfo.fromJson).toList(),
        path: path,
      );

  Map<String, Object?> toJson() => {
        'version': version,
        'conversation': [for (final c in conversation) c.toJson()],
        'threads': [for (final t in threads) t.toJson()],
      };
}

/// A calendar entry that is not a task: an appointment, a call, a reminder.
/// Stored in events.json at the agenda root.
class AgendaEvent {
  AgendaEvent({required this.id, required this.date, required this.title, this.time, this.end, this.note, this.task, this.project});

  final String id;

  /// `YYYY-MM-DD`.
  final String date;

  /// `HH:MM` or null for an all-day entry; [end] likewise.
  final String? time;
  final String? end;
  final String title;
  final String? note;

  /// Optional links: a task UID and a project id.
  final String? task;
  final String? project;

  DateTime? get day => DateTime.tryParse(date);

  /// Start as a DateTime (midnight when there is no time).
  DateTime? get start => DateTime.tryParse(time == null ? date : '${date}T$time');

  factory AgendaEvent.fromJson(Map<String, Object?> j) => AgendaEvent(
        id: '${j['id'] ?? ''}',
        date: '${j['date'] ?? ''}',
        title: '${j['title'] ?? ''}',
        time: j['time'] as String?,
        end: j['end'] as String?,
        note: j['note'] as String?,
        task: j['task'] as String?,
        project: j['project'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'date': date,
        'time': time,
        'end': end,
        'title': title,
        'note': note,
        'task': task,
        'project': project,
      };
}

/// How often a recurring item comes back.
enum RecurringInterval {
  yearly('yearly', 'year'),
  monthly('monthly', 'month'),
  days('days', 'day');

  const RecurringInterval(this.id, this.label);
  final String id;
  final String label;

  static RecurringInterval parse(Object? s) =>
      values.firstWhere((v) => v.id == s, orElse: () => RecurringInterval.yearly);
}

/// One recurring point under a [RecurringTopic]: a yearly insurance renewal, a
/// periodic inspection. Stored in recurring.json at the agenda root.
class RecurringItem {
  RecurringItem({
    required this.id,
    required this.text,
    this.interval = RecurringInterval.yearly,
    this.every = 1,
    required this.anchor,
    required this.nextDue,
    this.lastDone,
    this.note,
    this.project,
    this.task,
    this.history = const [],
  });

  final String id;
  final String text;
  final RecurringInterval interval;

  /// Repeat every [every] years/months/days (positive, default 1).
  final int every;

  /// The first/original due date, `YYYY-MM-DD`. The schedule stays anchored to
  /// this date; [nextOccurrenceAfter] steps from the previous `next_due`, not
  /// from today, so marking an item done late or early doesn't drift it.
  final String anchor;

  /// The date that drives the calendar and the checker, `YYYY-MM-DD`.
  final String nextDue;
  final String? lastDone;
  final String? note;

  /// Optional links: a project id and a task UID, same shape as [AgendaEvent].
  final String? project;
  final String? task;
  final List<HistoryEntry> history;

  DateTime? get nextDueDate => DateTime.tryParse(nextDue);

  /// The next `next_due` after [due], stepping by [interval]/[every] from it
  /// (not from today).
  String nextOccurrenceAfter(String due) {
    final d = DateTime.tryParse(due) ?? DateTime.now();
    switch (interval) {
      case RecurringInterval.yearly:
        return _iso(_addMonths(d, 12 * every));
      case RecurringInterval.monthly:
        return _iso(_addMonths(d, every));
      case RecurringInterval.days:
        return _iso(d.add(Duration(days: every)));
    }
  }

  factory RecurringItem.fromJson(Map<String, Object?> j) => RecurringItem(
        id: '${j['id'] ?? ''}',
        text: '${j['text'] ?? ''}',
        interval: RecurringInterval.parse(j['interval']),
        every: ((j['every'] as num?)?.toInt() ?? 1).clamp(1, 1 << 20),
        anchor: '${j['anchor'] ?? ''}',
        nextDue: '${j['next_due'] ?? ''}',
        lastDone: j['last_done'] as String?,
        note: j['note'] as String?,
        project: j['project'] as String?,
        task: j['task'] as String?,
        history: listOfMaps(j['history']).map(HistoryEntry.fromJson).toList(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        'interval': interval.id,
        'every': every,
        'anchor': anchor,
        'next_due': nextDue,
        'last_done': lastDone,
        'note': note,
        'project': project,
        'task': task,
        'history': [for (final h in history) h.toJson()],
      };
}

/// A group of [RecurringItem]s under one heading, e.g. "Campervan".
class RecurringTopic {
  RecurringTopic({required this.id, required this.title, this.items = const []});
  final String id;
  final String title;
  final List<RecurringItem> items;

  factory RecurringTopic.fromJson(Map<String, Object?> j) => RecurringTopic(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        items: listOfMaps(j['items']).map(RecurringItem.fromJson).toList(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'items': [for (final i in items) i.toJson()],
      };
}

DateTime _addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final year = d.year + total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, d.day > lastDay ? lastDay : d.day);
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Everything under the agenda folder: projects with their tasks, the General topic and the events.
class Agenda {
  Agenda({
    required this.dir,
    this.projects = const [],
    GeneralTopic? general,
    this.events = const [],
    this.recurringTopics = const [],
    this.errors = const [],
  }) : general = general ?? GeneralTopic(path: '$dir/general.json');

  final String dir;
  final List<Project> projects;
  final GeneralTopic general;

  /// Calendar entries from events.json, by date and time.
  final List<AgendaEvent> events;

  /// Recurring topics and items from recurring.json.
  final List<RecurringTopic> recurringTopics;

  /// Files that could not be read or parsed (path: message). Never fatal.
  final List<String> errors;

  String get projectsDir => '$dir/projects';
  String get eventsPath => '$dir/events.json';
  String get recurringPath => '$dir/recurring.json';

  Iterable<(RecurringTopic, RecurringItem)> get allRecurringItems sync* {
    for (final t in recurringTopics) {
      for (final i in t.items) {
        yield (t, i);
      }
    }
  }

  Iterable<(Project, AgendaTask)> get allTasks sync* {
    for (final p in projects) {
      for (final t in p.tasks) {
        yield (p, t);
      }
    }
  }

  Project? projectById(String id) => projects.where((p) => p.id == id).firstOrNull;

  (Project, AgendaTask)? taskByUid(String uid) => allTasks.where((e) => e.$2.uid == uid).firstOrNull;

  List<(Project, AgendaTask)> get needsUser =>
      allTasks.where((e) => e.$2.status == TaskStatus.needsUser).toList();

  /// Distinct sender patterns across open tasks.
  List<String> get watchedSenders => {
        for (final (_, t) in allTasks)
          if (t.isOpen)
            for (final w in t.watch)
              if (w.from.trim().isNotEmpty) w.from.trim().toLowerCase(),
      }.toList();

  /// Project deadlines, open task due dates and events, soonest first.
  List<Deadline> upcoming({DateTime? from}) {
    final today = _day(from ?? DateTime.now());
    final seen = <String>{};
    final all = <Deadline>[
      for (final p in projects) ...p.deadlines,
      for (final (p, t) in allTasks)
        if (t.isOpen && t.due != null) Deadline(date: t.due!, text: t.name, task: t.uid, projectId: p.id),
      for (final e in events) Deadline(date: e.date, text: e.time == null ? e.title : '${e.time} ${e.title}', task: e.task, projectId: e.project),
      for (final (topic, item) in allRecurringItems)
        if (item.nextDue.isNotEmpty) Deadline(date: item.nextDue, text: '${topic.title}: ${item.text}', task: item.task, projectId: item.project),
    ];
    final out = <Deadline>[];
    for (final d in all) {
      final w = d.when;
      if (w == null || _day(w).isBefore(today)) continue;
      if (seen.add('${d.date}|${d.project}|${d.task}|${d.text}')) out.add(d);
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  /// Due dates in the past that still belong to an open task.
  List<Deadline> overdue({DateTime? from}) {
    final today = _day(from ?? DateTime.now());
    return [
      for (final (p, t) in allTasks)
        if (t.isOpen && t.dueDate != null && _day(t.dueDate!).isBefore(today))
          Deadline(date: t.due!, text: t.name, task: t.uid, projectId: p.id),
    ];
  }

  // ---- threads and nodes ------------------------------------------------------

  /// Threads of [node] (`general`, `project:<id>`, `task:<uid>`), oldest first.
  List<ThreadInfo> threadsFor(String node) {
    final list = [..._threadsOf(node)]..sort((a, b) => a.created.compareTo(b.created));
    return list;
  }

  List<ThreadInfo> _threadsOf(String node) {
    if (node == 'general') return general.threads;
    if (node.startsWith('project:')) return projectById(node.substring(8))?.threads ?? const [];
    if (node.startsWith('task:')) return taskByUid(node.substring(5))?.$2.threads ?? const [];
    return const [];
  }

  ThreadInfo? activeThread(String node) => _activeThread(_threadsOf(node));

  List<ConversationEntry> conversationOf(String node) {
    if (node == 'general') return general.conversation;
    if (node.startsWith('project:')) return projectById(node.substring(8))?.conversation ?? const [];
    if (node.startsWith('task:')) return taskByUid(node.substring(5))?.$2.conversation ?? const [];
    return const [];
  }

  Set<String> get allThreadIds => {
        for (final t in general.threads) t.id,
        for (final p in projects) ...[
          for (final t in p.threads) t.id,
          for (final task in p.tasks)
            for (final t in task.threads) t.id,
        ],
      };

  /// The node a thread belongs to and the thread itself.
  (String, ThreadInfo)? threadById(String id) {
    for (final t in general.threads) {
      if (t.id == id) return ('general', t);
    }
    for (final p in projects) {
      for (final t in p.threads) {
        if (t.id == id) return (p.node, t);
      }
      for (final task in p.tasks) {
        for (final t in task.threads) {
          if (t.id == id) return (task.node, t);
        }
      }
    }
    return null;
  }

  /// The JSON file that holds [node]'s conversation and threads, or null.
  String? jsonPathForNode(String node) {
    if (node == 'general') return general.path;
    if (node.startsWith('project:')) return projectById(node.substring(8))?.jsonPath;
    if (node.startsWith('task:')) return taskByUid(node.substring(5))?.$2.jsonPath;
    return null;
  }
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

List<Map<String, Object?>> listOfMaps(Object? v) =>
    v is List ? v.whereType<Map<String, Object?>>().toList() : const [];

extension AgendaLinks on Agenda {
  /// Tasks that continue [uid] (their `follows` points at it).
  List<AgendaTask> successorsOf(String uid) => [
        for (final (_, t) in allTasks)
          if (t.follows == uid) t,
      ];
}
