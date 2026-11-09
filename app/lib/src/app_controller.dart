import 'dart:async';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:agenda_core/agenda_core.dart' as store;
import 'package:flutter/foundation.dart';

import 'agent/api_chat.dart';
import 'agent/file_tools.dart';
import 'chat_controller.dart';
import 'secrets.dart';
import 'sync_service.dart';
import 'system_integration.dart';
import 'task_files.dart';
import 'thread_context.dart';

/// Node keys for what the window shows: `general` (the cross-project chat, the
/// default right pane), `project:<id>`, `task:<uid>` (right pane), and the full
/// pages `runs`, `settings`, `recurring`, `new:<project id>`, `file:<uid>|<absolute path>`.
String taskNode(AgendaTask t) => t.node;
String projectNode(Project p) => p.node;
String fileNode(AgendaTask t, TaskFile f) => 'file:${t.uid}|${f.path}';

/// App-wide state. File-driven: projects/, general.json, runs/ and the Claude
/// session folder are watched, so background runs and chats show up live.
class AppController extends ChangeNotifier {
  AppController(this.settings);

  final AgendaSettings settings;
  AgendaPaths get paths => settings.paths;

  Agenda? agenda;
  String? agendaError;
  List<RunRecord> runs = const [];
  List<SessionInfo> sessions = const [];
  bool bridgeUp = false;
  bool timerOn = false;
  bool autostartOn = false;
  DateTime? nextCheck;

  String selected = 'general';

  /// The central personal-information folder shown on the Personal info page.
  late String personalDir = settings.personalDir;

  /// Sync with the other devices of the account, over Reticulum (LAN and hubs).
  late final sync = SyncService(settings: settings, onFilesChanged: () => _later('agenda', _loadAgenda));

  /// The phone build: no Claude Code, no systemd, no tray.
  static bool get isMobile => Platform.isAndroid;

  /// The last right-pane node, where the back button of a full page returns.
  String _paneNode = 'general';

  /// Left pane: calendar or flat list; the calendar shows a week or a month
  /// around [calendarAnchor]; [projectFilter] limits both to one project.
  bool listMode = false;
  bool monthView = false;
  DateTime calendarAnchor = DateTime.now();
  String? projectFilter;

  /// Files per task node, resolved in the background.
  final taskFiles = <String, List<TaskFile>>{};
  bool showDone = false;

  /// The one chat of each node, by node; `session:<id>` for a session opened read-only in General.
  final _chats = <String, ChatController>{};

  /// A session that is not a thread (terminal, background run) shown in General instead of its chat.
  String? _generalSession;

  final _subs = <StreamSubscription<FileSystemEvent>>[];
  final _debounce = <String, Timer>{};
  Timer? _slowRefresh;

  int get needsUserCount => agenda?.needsUser.length ?? 0;

  bool get runInProgress {
    if (runs.isEmpty) return false;
    final r = runs.first;
    return r.ended == null && DateTime.now().difference(r.started) < Duration(minutes: settings.runTimeoutMinutes + 5);
  }

  Future<void> start() async {
    await Directory(paths.projectsDir).create(recursive: true);
    await Future.wait([_loadAgenda(), if (!isMobile) ...[_loadRuns(), _loadSessions(), refreshSystem()]]);
    _watch(paths.agendaDir, (e) {
      if (e.path.endsWith('/general.json') || e.path.endsWith('/events.json') || e.path.endsWith('/recurring.json')) {
        _later('agenda', _loadAgenda);
        sync.syncSoon();
      }
    });
    // Every synced folder: a local change asks the other devices to sync.
    await Directory(personalDir).create(recursive: true);
    _watch(personalDir, _onSyncedEvent, recursive: true);
    for (final d in const ['accounts', 'prompts', 'shared']) {
      await Directory('${paths.agendaDir}/$d').create(recursive: true);
      _watch('${paths.agendaDir}/$d', _onSyncedEvent, recursive: true);
    }
    _watch(paths.projectsDir, _onProjectsEvent, recursive: true);
    unawaited(sync.start());
    if (isMobile) return;
    await Directory(paths.runsDir).create(recursive: true);
    _watch(paths.runsDir, (_) => _later('runs', _loadRuns));
    await Directory(paths.claudeProjectDir).create(recursive: true);
    _watch(paths.claudeProjectDir, (_) => _later('sessions', _loadSessions, ms: 1500));
    // Bridge and the timer have no change events; refresh them every few minutes.
    _slowRefresh = Timer.periodic(const Duration(minutes: 5), (_) {
      refreshSystem();
      _later('agenda', _loadAgenda);
    });
  }

  void _onSyncedEvent(FileSystemEvent e) {
    if (e.path.contains('.tmp-')) return;
    sync.syncSoon();
    // Model and review hour changed on another device.
    if (e.path == settings.sharedFile) {
      _later('settings', () async {
        await settings.reloadShared();
        notifyListeners();
      });
    }
  }

  void _onProjectsEvent(FileSystemEvent e) {
    final p = e.path;
    if (p.contains('.tmp-')) return;
    sync.syncSoon();
    if (p.endsWith('/task.json') || p.endsWith('/project.json')) {
      _later('agenda', _loadAgenda);
    } else {
      // Drafts and other files show up in the tree without waiting for a turn to end.
      _later('files', _resolveFiles, ms: 800);
    }
  }

  void _watch(String dir, void Function(FileSystemEvent) onEvent, {bool recursive = false}) {
    try {
      _subs.add(Directory(dir).watch(recursive: recursive).listen(onEvent, onError: (Object e) {
        debugPrint('watch on $dir failed: $e');
      }));
    } on FileSystemException catch (e) {
      debugPrint('cannot watch $dir: $e');
    }
  }

  void _later(String key, Future<void> Function() fn, {int ms = 300}) {
    _debounce[key]?.cancel();
    _debounce[key] = Timer(Duration(milliseconds: ms), () => fn());
  }

  Future<void> _loadAgenda() async {
    try {
      final fresh = await loadAgenda(paths.agendaDir);
      agenda = _mergeWithPrevious(fresh);
      agendaError = fresh.errors.isEmpty ? null : fresh.errors.join('\n');
    } on FileSystemException catch (e) {
      agendaError = 'projects folder not readable: ${e.message}';
    }
    notifyListeners();
    _later('files', _resolveFiles, ms: 50);
  }

  /// A half-written task.json (Claude mid-edit) must not make its row vanish for
  /// a moment: keep the last good copy of anything that failed to parse this time.
  Agenda _mergeWithPrevious(Agenda fresh) {
    final old = agenda;
    if (old == null || fresh.errors.isEmpty) return fresh;
    final projects = <Project>[];
    for (final p in fresh.projects) {
      final oldP = old.projectById(p.id);
      final tasks = [...p.tasks];
      if (oldP != null) {
        for (final t in oldP.tasks) {
          final broken = fresh.errors.any((e) => e.startsWith(t.jsonPath) || e.startsWith(t.dir));
          if (broken && !tasks.any((x) => x.uid == t.uid)) tasks.add(t);
        }
      }
      projects.add(Project(
        id: p.id,
        title: p.title,
        version: p.version,
        created: p.created,
        status: p.status,
        docs: p.docs,
        deadlines: p.deadlines,
        conversation: p.conversation,
        threads: p.threads,
        dir: p.dir,
        tasks: tasks,
      ));
    }
    for (final oldP in old.projects) {
      if (!projects.any((p) => p.id == oldP.id) && fresh.errors.any((e) => e.startsWith(oldP.jsonPath))) {
        projects.add(oldP);
      }
    }
    projects.sort((a, b) => a.dir.compareTo(b.dir));
    return Agenda(dir: fresh.dir, projects: projects, general: fresh.general, events: fresh.events, recurringTopics: fresh.recurringTopics, errors: fresh.errors);
  }

  Future<void> _loadRuns() async {
    runs = await listRuns(paths.runsDir);
    notifyListeners();
  }

  Future<void> _loadSessions() async {
    sessions = await listSessions(paths.claudeProjectDir);
    notifyListeners();
  }

  Future<void> refreshSystem() async {
    final r = await Future.wait([
      BridgeMail.reachable(),
      SystemIntegration.timerEnabled(),
      SystemIntegration.autostartEnabled(),
      SystemIntegration.nextCheck(),
    ]);
    bridgeUp = r[0] as bool;
    timerOn = r[1] as bool;
    autostartOn = r[2] as bool;
    nextCheck = r[3] as DateTime?;
    notifyListeners();
  }

  // ---- tree -----------------------------------------------------------------

  /// Pages that take the whole window instead of the right pane.
  static bool isFullPage(String node) =>
      node == 'runs' || node == 'settings' || node == 'personal' || node == 'share' || node == 'recurring' || node.startsWith('new:') || node.startsWith('file:');

  /// Project whose chat the right pane shows when no task is open.
  String? _lastProject;

  Project? get homeProject {
    final a = agenda;
    if (a == null) return null;
    return a.projectById(projectFilter ?? '') ?? a.projectById(_lastProject ?? '') ?? a.projects.firstOrNull;
  }

  /// Project of the right pane: the open task's or project's, else [homeProject]; null for the General chat.
  String? get paneProject {
    final n = selected;
    if (n == 'chat') return null;
    if (taskFor(n) case (final p, _)?) return p.id;
    return projectFor(n)?.id ?? homeProject?.id;
  }

  void select(String node) {
    selected = node;
    if (taskFor(node) case (final p, _)?) _lastProject = p.id;
    if (projectFor(node) case final p?) _lastProject = p.id;
    if (!isFullPage(node)) _paneNode = node;
    notifyListeners();
  }

  /// Leaves a full page for the right pane shown before it.
  void back() => select(_paneNode);

  void setListMode(bool v) {
    listMode = v;
    notifyListeners();
  }

  void setMonthView(bool v) {
    monthView = v;
    notifyListeners();
  }

  void setProjectFilter(String? id) {
    projectFilter = id;
    if (id != null) _lastProject = id;
    notifyListeners();
  }

  /// Moves the calendar by [steps] weeks or months; 0 jumps to today.
  void moveCalendar(int steps) {
    final a = calendarAnchor;
    calendarAnchor = steps == 0
        ? DateTime.now()
        : monthView
        ? DateTime(a.year, a.month + steps, 1)
        : DateTime(a.year, a.month, a.day + 7 * steps);
    notifyListeners();
  }

  /// Tasks that pass the project filter.
  Iterable<(Project, AgendaTask)> get visibleTasks =>
      (agenda?.allTasks ?? const <(Project, AgendaTask)>[]).where((e) => projectFilter == null || e.$1.id == projectFilter);

  /// Events that pass the project filter (by their project or their task's project).
  List<AgendaEvent> get visibleEvents => [
    for (final e in agenda?.events ?? const <AgendaEvent>[])
      if (projectFilter == null || e.project == projectFilter || (e.task != null && agenda?.taskByUid(e.task!)?.$1.id == projectFilter)) e,
  ];

  /// Recurring topics and items, independent of the project filter.
  List<RecurringTopic> get visibleRecurringTopics => agenda?.recurringTopics ?? const [];

  void setShowDone(bool v) {
    showDone = v;
    notifyListeners();
  }

  (Project, AgendaTask)? taskFor(String node) =>
      node.startsWith('task:') ? agenda?.taskByUid(node.substring(5)) : null;

  Project? projectFor(String node) => node.startsWith('project:') ? agenda?.projectById(node.substring(8)) : null;

  // ---- threads --------------------------------------------------------------

  List<ThreadInfo> threadsFor(String node) => agenda?.threadsFor(node) ?? const [];

  ThreadInfo? threadById(String id) => agenda?.threadById(id)?.$2;

  String? nodeOfThread(String id) => agenda?.threadById(id)?.$1;

  /// The JSON file holding [node]'s conversation and threads.
  String? nodeFile(String node) => node == 'general' ? paths.generalFile : agenda?.jsonPathForNode(node);

  /// The newest session of [node] whose transcript is on this device, so it can be resumed.
  String? _resumable(String node) {
    final local = {for (final s in sessions) s.id};
    return threadsFor(node).reversed.where((t) => local.contains(t.id)).firstOrNull?.id;
  }

  /// The one chat of [node]: every stored message of the node, continuing its newest session.
  /// Archived flags of old threads are ignored; nothing is ever hidden.
  ChatController chatFor(String node) {
    final viewing = node == 'general' ? _generalSession : null;
    if (viewing != null) return _chats['session:$viewing'] ??= _makeChat(node, viewing, readOnly: true, earlier: const []);
    final cached = _chats[node];
    // Built before the session list loaded: switch to the session to resume while nothing was sent.
    if (cached != null && cached.sessionId == null && !cached.busy && cached.draft.text.isEmpty) {
      if (_resumable(node) != null) _chats.remove(node);
    }
    return _chats[node] ??= () {
      final id = _resumable(node);
      final all = agenda?.conversationOf(node) ?? const <ConversationEntry>[];
      final hasTranscript = id != null;
      return _makeChat(node, id, earlier: [
        for (final e in all)
          if (!hasTranscript || e.session != id) e,
      ]);
    }();
  }

  ChatController _makeChat(String node, String? sessionId, {bool readOnly = false, required List<ConversationEntry> earlier}) {
    late final ChatController chat;
    chat = ChatController(
      cwd: paths.agendaDir,
      node: node,
      sessionId: sessionId,
      transcriptPath: sessionId == null ? null : '${paths.claudeProjectDir}/$sessionId.jsonl',
      stored: sessionId == null ? const [] : (agenda?.conversationOf(node) ?? const []).where((e) => e.session == sessionId).toList(),
      earlier: earlier,
      model: settings.model,
      systemPrompt: () => threadSystemPrompt(node, agenda, currentSession: chat.sessionId),
      onSessionStarted: _threadStarted,
      onMessage: _persistMessage,
      onTurnFinished: (_) => refreshFiles(),
      readOnly: readOnly,
      engine: isMobile ? (id) => _apiChat(id) : null,
    );
    unawaited(chat.loadHistory());
    return chat;
  }

  /// Claude on the phone: the Messages API with file tools on the synced folders.
  ApiChat _apiChat(String? sessionId) => ApiChat(
    tools: FileTools(agendaDir: paths.agendaDir, personalDir: personalDir),
    transcriptDir: paths.claudeProjectDir,
    apiKey: () => Secrets.apiKey(settings),
    baseSystem: _phoneSystemPrompt,
    sessionId: sessionId,
  );

  Future<String> _phoneSystemPrompt() async {
    Future<String> read(String path) async {
      final f = File(path);
      return await f.exists() ? await f.readAsString() : '(missing: not synced yet)';
    }

    return '''
You are Claude inside the agenda app on Max's Android phone. You help him move real-life tasks
forward (letters, forms, phone numbers, rules, planning). The agenda folder and ~/personal are synced
with his other devices (desktop and laptops); your file changes reach them at the next sync.

Your tools: Read, Write, Edit, Glob, Grep on the agenda folder (paths relative to it, e.g.
projects/taxes/data/TASKS.md) and on ~/personal (paths starting with ~/personal/), plus web_search and
web_fetch. There is no shell, no mail access and no agenda-new here: for new tasks or projects, mail
and PDF form filling, tell Max it has to be done on the desktop, or prepare everything so the desktop
session can finish it. Today is ${todayIso()}.

The rules of the agenda folder follow (CLAUDE.md, then docs/format.md, then ~/personal/README.md).
Where they mention tools you do not have, use the file tools instead.

=== CLAUDE.md ===
${await read('${paths.agendaDir}/CLAUDE.md')}

=== docs/format.md ===
${await read('${paths.agendaDir}/docs/format.md')}

=== ~/personal/README.md ===
${await read('$personalDir/README.md')}
''';
  }

  Future<void> _persistMessage(ChatController chat, ConversationEntry e) async {
    final path = nodeFile(chat.node);
    if (path == null) return;
    if (chat.node == 'general') await updateGeneral(paths.agendaDir, (_) {});
    await store.appendConversation(path, e);
  }

  Future<void> _threadStarted(ChatController chat) async {
    final id = chat.sessionId!;
    if (chat.readOnly || threadById(id) != null) return notifyListeners();
    final info = ThreadInfo(id: id, created: DateTime.now());
    if (chat.node == 'general') {
      await updateGeneral(paths.agendaDir, (j) => ((j['threads'] ??= <Object?>[]) as List).add(info.toJson()));
    } else {
      final path = nodeFile(chat.node);
      if (path != null) await store.addThread(path, info);
    }
    await _loadAgenda();
    notifyListeners();
  }

  /// Sessions in this folder that are neither threads nor background runs
  /// (e.g. terminal conversations), for the General topic.
  List<SessionInfo> get otherSessions {
    final ids = agenda?.allThreadIds ?? const <String>{};
    return sessions.where((s) => !ids.contains(s.id)).toList();
  }

  /// Opens a session that is not a thread (terminal or background run) in General.
  void openSession(String sessionId) {
    _generalSession = sessionId;
    selected = _paneNode = 'chat';
    notifyListeners();
  }

  /// Id of the other session shown in General, or null for the General chat itself.
  String? get generalSession => _generalSession;

  /// Back from an opened session to the General chat.
  void closeSession() {
    _generalSession = null;
    notifyListeners();
  }

  // ---- files ----------------------------------------------------------------

  /// Rescans every task for files (in its folder, explicit, mentioned in its text or loaded conversations).
  Future<void> _resolveFiles() async {
    final a = agenda;
    if (a == null) return;
    final next = <String, List<TaskFile>>{};
    for (final (p, task) in a.allTasks) {
      final node = taskNode(task);
      final texts = [
        for (final c in _chats.values)
          if (c.node == node)
            for (final i in c.items)
              if (i.role != ChatRole.tool) i.text,
      ];
      next[node] = await resolveTaskFiles(agendaDir: paths.agendaDir, project: p, task: task, extraTexts: texts);
    }
    taskFiles
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void refreshFiles() => _later('files', _resolveFiles, ms: 50);

  List<TaskFile> filesFor(AgendaTask t) => taskFiles[taskNode(t)] ?? const [];

  /// Resolves a `file:` node to its task and file.
  (Project, AgendaTask, TaskFile)? fileFor(String node) {
    if (!node.startsWith('file:')) return null;
    final bar = node.indexOf('|');
    if (bar < 0) return null;
    final task = taskFor('task:${node.substring(5, bar)}');
    if (task == null) return null;
    final path = node.substring(bar + 1);
    final f = filesFor(task.$2).where((f) => f.path == path).firstOrNull;
    return f == null ? null : (task.$1, task.$2, f);
  }

  /// Marks [f] approved in task.json (adds it to the task's files if needed).
  Future<void> approveFile(AgendaTask t, TaskFile f) async {
    await store.setFileStatus(t, f.rel, 'approved');
    await _loadAgenda();
  }

  /// Writes [text] to [f] (atomic) and rescans.
  Future<void> saveFile(TaskFile f, String text) async {
    await writeAtomic(f.path, text);
    refreshFiles();
  }

  // ---- task actions -----------------------------------------------------------

  Future<void> setTaskStatus(AgendaTask t, TaskStatus s) async {
    if (s == t.status) return;
    await store.setTaskStatus(t, s, source: 'the agenda app');
    await _loadAgenda();
  }

  Future<void> toggleItem(AgendaTask t, Item item) async {
    await store.setItemDone(t, item.id, !item.done);
    await _loadAgenda();
  }

  Future<void> addTaskItem(AgendaTask t, String text) async {
    if (text.trim().isEmpty) return;
    await store.addItem(t, text.trim());
    await _loadAgenda();
  }


  // ---- creating and editing -----------------------------------------------------

  Future<void> createProject(String id, String title) async {
    final p = await store.createProject(agendaDir: paths.agendaDir, id: id, title: title);
    await _loadAgenda();
    select(projectNode(p));
  }

  /// Creates a task, opens its page and, when [firstMessage] is given, sends it
  /// to Claude as the first turn of the task's conversation.
  Future<AgendaTask> createTask(
    Project p, {
    required String name,
    String? due,
    String? scheduled,
    int priority = 3,
    String? nextStep,
    String? firstMessage,
  }) async {
    final t = await store.createTask(project: p, name: name, due: due, scheduled: scheduled, priority: priority, nextStep: nextStep);
    await _loadAgenda();
    select(taskNode(t));
    if (firstMessage != null && firstMessage.trim().isNotEmpty) {
      unawaited(chatFor(taskNode(t)).send(firstMessage.trim()));
    }
    return t;
  }

  /// Node key of the composer for a new task in project [id].
  static String newTaskNode(String id) => 'new:$id';

  /// Creates the task that continues [from]; optionally moves its open items and closes it.
  Future<AgendaTask> spawnFollowUp(
    Project p,
    AgendaTask from, {
    required String name,
    String? due,
    String? nextStep,
    bool moveOpenItems = false,
    bool closeOrigin = false,
  }) async {
    final t = await store.spawnFollowUp(project: p, from: from, name: name, due: due, nextStep: nextStep, moveOpenItems: moveOpenItems);
    if (closeOrigin && from.isOpen) await store.setTaskStatus(from, TaskStatus.done, source: 'the agenda app (follow-up ${t.uid} created)');
    await _loadAgenda();
    select(taskNode(t));
    return t;
  }

  Future<void> editTask(AgendaTask t, Map<String, Object?> changes) async {
    await store.editTaskFields(t, changes);
    await _loadAgenda();
  }

  Future<void> removeTaskItem(AgendaTask t, Item item) async {
    await store.removeItem(t, item.id);
    await _loadAgenda();
  }

  /// Copies a photo or other file into [t]'s folder (photos/ for images) and records it.
  Future<String> addFileToTask(AgendaTask t, String sourcePath, {String? name}) async {
    final now = DateTime.now();
    final stamp = '${now.year}-${_two(now.month)}-${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final ext = sourcePath.contains('.') ? sourcePath.substring(sourcePath.lastIndexOf('.')).toLowerCase() : '';
    final image = const {'.jpg', '.jpeg', '.png', '.webp', '.heic'}.contains(ext);
    final rel = '${image ? 'photos/' : ''}${name ?? stamp}$ext';
    final dest = File('${t.dir}/$rel');
    await dest.parent.create(recursive: true);
    await File(sourcePath).copy(dest.path);
    await store.appendHistory(t.jsonPath, '${image ? 'Photo' : 'File'} $rel added from ${isMobile ? 'the phone' : 'the agenda app'}');
    await _loadAgenda();
    refreshFiles();
    return rel;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Files shared into the app from another app (Android share sheet), waiting for a task.
  List<String> pendingShares = const [];

  void receiveShares(List<String> paths) {
    if (paths.isEmpty) return;
    pendingShares = paths;
    select('share');
  }

  /// Adds the shared files to [t] and opens it.
  Future<int> addSharesToTask(AgendaTask t) async {
    final files = pendingShares;
    pendingShares = const [];
    var n = 0;
    for (final (i, path) in files.indexed) {
      if (!await File(path).exists()) continue;
      final now = DateTime.now();
      final name = '${now.year}-${_two(now.month)}-${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}${files.length > 1 ? '_${i + 1}' : ''}';
      await addFileToTask(t, path, name: name);
      n++;
    }
    select(taskNode(t));
    return n;
  }

  // ---- calendar --------------------------------------------------------------------

  /// Plans [t] on a day (`YYYY-MM-DD`) or a day and time (`YYYY-MM-DDTHH:MM`); null unplans it.
  Future<void> scheduleTask(AgendaTask t, String? when) async {
    if (t.scheduled == when) return;
    await store.editTaskFields(t, {'scheduled': when});
    await _loadAgenda();
  }

  /// Adds the event (when its id is empty) or replaces it.
  Future<void> saveEvent(AgendaEvent e) async {
    if (e.id.isEmpty) {
      await store.addEvent(paths.agendaDir, e);
    } else {
      await store.updateEvent(paths.agendaDir, e);
    }
    await _loadAgenda();
  }

  Future<void> deleteEvent(AgendaEvent e) async {
    await store.removeEvent(paths.agendaDir, e.id);
    await _loadAgenda();
  }

  // ---- recurring --------------------------------------------------------------

  Future<void> addRecurringTopic(String title) async {
    await store.addRecurringTopic(paths.agendaDir, title);
    await _loadAgenda();
  }

  Future<void> renameRecurringTopic(String topicId, String title) async {
    await store.renameRecurringTopic(paths.agendaDir, topicId, title);
    await _loadAgenda();
  }

  Future<void> deleteRecurringTopic(String topicId) async {
    await store.removeRecurringTopic(paths.agendaDir, topicId);
    await _loadAgenda();
  }

  /// Adds the item (when its id is empty) or replaces it.
  Future<void> saveRecurringItem(String topicId, RecurringItem item) async {
    if (item.id.isEmpty) {
      await store.addRecurringItem(paths.agendaDir, topicId, item);
    } else {
      await store.updateRecurringItem(paths.agendaDir, topicId, item);
    }
    await _loadAgenda();
  }

  Future<void> deleteRecurringItem(String topicId, String itemId) async {
    await store.removeRecurringItem(paths.agendaDir, topicId, itemId);
    await _loadAgenda();
  }

  Future<void> markRecurringItemDone(String topicId, String itemId) async {
    await store.markRecurringItemDone(paths.agendaDir, topicId, itemId);
    await _loadAgenda();
  }
  // ---- system actions ------------------------------------------------------------

  Future<void> runNow() async {
    await SystemIntegration.runNow();
    Timer(const Duration(seconds: 3), refreshSystem);
  }

  Future<void> setAutostart(bool on) async {
    settings.startAtLogin = on;
    await settings.save();
    await SystemIntegration.setAutostart(on);
    await refreshSystem();
  }

  Future<void> setBackgroundChecks(bool on) async {
    settings.backgroundChecks = on;
    await settings.save();
    await SystemIntegration.setTimer(on);
    await refreshSystem();
  }

  Future<void> setInterval(int minutes) async {
    settings.intervalMinutes = minutes;
    await settings.save();
    await SystemIntegration.setInterval(minutes);
    await refreshSystem();
  }

  Future<void> saveSettings() async {
    await settings.save();
    notifyListeners();
  }

  Future<void> shutdown() async {
    await sync.stop();
    for (final c in _chats.values) {
      await c.close();
    }
    _chats.clear();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final t in _debounce.values) {
      t.cancel();
    }
    _slowRefresh?.cancel();
    super.dispose();
  }
}
