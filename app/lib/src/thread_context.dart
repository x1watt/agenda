import 'package:agenda_core/agenda_core.dart';

/// Old marker that used to close a chat; no longer acted on, only hidden if it ever shows up.
final reshapeMarker = RegExp(r'\[\[new-thread:\s*([^\]]*)\]\]');

/// Removes the reshape marker from text shown to the user.
String stripMarker(String text) => text.replaceAll(reshapeMarker, '').trimRight();

const _rules = '''
Rules for this thread:
- Follow CLAUDE.md in this folder and docs/format.md. When a task changes, edit its task.json
  directly (status, next_step, waiting_on, due, scheduled, items, files) and append a dated history entry;
  keep the file valid JSON. Never rewrite or delete history entries. Never touch the
  conversation[] or threads[] arrays, they belong to the app. Update the project's checklist in
  its data/ folder in the same step when it exists.
- Put files you produce for a task into the task's folder and list them in its files[] with
  status needs_review and a path relative to that folder. Project-wide material goes to data/.
  Never write into sources/.
- New tasks and projects only through `agenda-new` (see docs/format.md).
- Personal data (names, birth dates, family, IDs, bank accounts, addresses, contacts, documents)
  is collected in ~/personal: read ~/personal/README.md before asking the user or searching the
  projects, and add any new or changed personal fact there (with source and date) in the same step.
- Keep answers short and concrete; the user reads them in a small reading pane.
- Each task, project and the General topic has exactly one continuous chat in the app. Never end a
  reply with a [[new-thread: ...]] marker and never suggest starting a new chat.
''';

/// Tasks of [p] with a chat and the last message of each, the most recently discussed first.
List<(AgendaTask, ConversationEntry)> taskChats(Project p) => [
  for (final t in p.tasks)
    if (t.conversation.isNotEmpty) (t, t.conversation.last),
]..sort((a, b) => b.$2.at.compareTo(a.$2.at));

String _cut(String s, int n) => s.length > n ? '${s.substring(0, n)}...' : s;

/// The last stored messages of [node] from other sessions, so a fresh session knows what was said.
String _recent(Agenda agenda, String node, String? currentSession) {
  final entries = agenda.conversationOf(node).where((e) => e.session != currentSession).toList();
  if (entries.isEmpty) return '';
  final tail = entries.length > 6 ? entries.sublist(entries.length - 6) : entries;
  final lines = tail.map((e) => '  ${e.at.toIso8601String().substring(0, 16)} ${e.role}: ${_cut(e.text.replaceAll('\n', ' '), 300)}');
  return '\nRecent conversation (earlier threads, stored by the app):\n${lines.join('\n')}\n';
}

/// System prompt appended to every turn of a thread about [node].
String threadSystemPrompt(String node, Agenda? agenda, {String? currentSession}) {
  if (agenda == null) return _rules;
  if (node == 'general') {
    return 'This conversation happens in the agenda app, in the General topic: anything across all '
        'projects (projects/*/project.json and their task folders). Keep answers short and concrete.'
        '${_recent(agenda, node, currentSession)}\n$_rules';
  }
  if (node.startsWith('project:')) {
    final p = agenda.projectById(node.substring(8));
    if (p == null) return _rules;
    final deadlines = p.deadlines.map((d) => '  - ${d.date}: ${d.text}${d.task == null ? '' : ' (task ${d.task})'}').join('\n');
    final chatLines = taskChats(p).take(5).map((c) => '  - ${c.$1.uid} "${c.$1.name}", ${c.$2.at.toIso8601String().substring(0, 16)} ${c.$2.role}: ${_cut(c.$2.text.replaceAll('\n', ' '), 200)}').join('\n');
    return '''
This conversation happens in the agenda app and is about the whole project "${p.title}"
(id ${p.id}, folder ${p.dir}, docs: ${p.docs.isEmpty ? '-' : p.docs.join(', ')}).
Project status: ${p.status ?? '-'}
Tasks: ${p.tasks.map((t) => '${t.uid} "${t.name}" [${t.status.id}]').join('; ')}
Deadlines:
${deadlines.isEmpty ? '  (none)' : deadlines}
Latest message in each task chat (open the task to see its whole chat):
${chatLines.isEmpty ? '  (none)' : chatLines}
${_recent(agenda, node, currentSession)}
$_rules''';
  }
  if (node.startsWith('task:')) {
    final hit = agenda.taskByUid(node.substring(5));
    if (hit == null) return _rules;
    final (p, t) = hit;
    final items = t.items.map((i) => '  - [${i.done ? 'x' : ' '}] ${i.id}: ${i.text}${i.due == null ? '' : ' (due ${i.due})'}').join('\n');
    final history = t.history.length > 10 ? t.history.sublist(t.history.length - 10) : t.history;
    final historyLines = history.map((h) => '  - ${h.date}: ${h.text}').join('\n');
    final files = t.files.map((f) => '  - ${f.path} [${f.status}]').join('\n');
    return '''
This conversation happens in the agenda app and is about ONE task. Current state from its task.json:
Project: ${p.title} (id ${p.id}, folder ${p.dir}, docs: ${p.docs.isEmpty ? '-' : p.docs.join(', ')})
Task: ${t.uid} "${t.name}"${t.legacyId == null ? '' : ' (formerly ${t.legacyId})'}
Task folder: ${t.dir} (task.json lives there; put files for this task there)
Status: ${t.status.id}, priority ${t.priority}, due ${t.due ?? '-'}, planned ${t.scheduled ?? '-'}, created ${t.created ?? '-'}
Next step: ${t.nextStep ?? '-'}
Waiting on: ${t.waitingOn ?? '-'}
Items:
${items.isEmpty ? '  (none)' : items}
Files:
${files.isEmpty ? '  (none)' : files}
History (last ${history.length}):
${historyLines.isEmpty ? '  (none)' : historyLines}
${_recent(agenda, node, currentSession)}
$_rules''';
  }
  return _rules;
}
