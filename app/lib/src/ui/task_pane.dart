import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_controller.dart';
import '../system_integration.dart';
import '../task_files.dart';
import '../thread_context.dart';
import 'dialogs.dart';
import 'theme.dart';
import 'thread_view.dart';

/// The right pane for a task: what it is, when, the next step and the
/// checklist on top; its chats with Claude below.
class TaskPane extends StatefulWidget {
  const TaskPane({super.key, required this.app, required this.project, required this.task});
  final AppController app;
  final Project project;
  final AgendaTask task;

  @override
  State<TaskPane> createState() => _TaskPaneState();
}

class _TaskPaneState extends State<TaskPane> {
  final _newItem = TextEditingController();
  bool showFiles = false;
  bool showHistory = false;

  AppController get app => widget.app;
  Project get p => widget.project;
  AgendaTask get t => widget.task;

  @override
  void dispose() {
    _newItem.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final text = _newItem.text.trim();
    if (text.isEmpty) return;
    _newItem.clear();
    await app.addTaskItem(t, text);
  }

  Future<void> _rename() async {
    final v = await textDialog(context, title: 'Rename task', initial: t.name);
    if (v != null && v.trim().isNotEmpty) await app.editTask(t, {'name': v.trim()});
  }

  Future<void> _editNextStep() async {
    final v = await textDialog(context, title: 'Next step', initial: t.nextStep ?? '', multiline: true, hint: 'What to do next, and by when');
    if (v != null) await app.editTask(t, {'next_step': v.trim().isEmpty ? null : v.trim()});
  }

  Future<void> _editWaiting() async {
    final v = await textDialog(context, title: 'Waiting on', initial: t.waitingOn ?? '', hint: 'Who or what, since when');
    if (v != null) await app.editTask(t, {'waiting_on': v.trim().isEmpty ? null : v.trim()});
  }

  Future<void> _pickDue() async {
    final d = await pickDate(context, initial: t.due);
    if (d != null) await app.editTask(t, {'due': d});
  }

  Future<void> _plan() async {
    final s = await pickSchedule(context, initial: t.scheduled);
    if (s != null) await app.scheduleTask(t, s);
  }

  Future<void> _photo(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
    if (picked == null) return;
    final rel = await app.addFileToTask(t, picked.path);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved $rel. It reaches your other devices with the next sync.')));
  }

  Future<void> _followUp() async {
    final d = await taskDialog(context, projectTitle: p.title, from: t);
    if (d == null) return;
    await app.spawnFollowUp(p, t, name: d.name, due: d.due, nextStep: d.nextStep, moveOpenItems: d.moveOpenItems, closeOrigin: d.closeOrigin);
  }

  Future<void> _finish() async {
    final open = t.items.where((i) => !i.done).length;
    final ok = await confirmDialog(
      context,
      title: 'Mark "${t.name}" done?',
      body: open > 0
          ? '$open checklist points are still open. They stay on the task as a record.'
          : 'The task moves to Done. You can still open it and its files.',
      action: 'Mark done',
    );
    if (ok) await app.setTaskStatus(t, TaskStatus.done);
  }

  @override
  Widget build(BuildContext context) {
    final files = app.filesFor(t);
    final toReview = files.where((f) => f.isText && !f.approved).length;
    final done = t.items.where((i) => i.done).length;
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: box.maxHeight * 0.5),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 10),
              children: [
                _facts(),
                const SizedBox(height: 10),
                Panel(
                  onTap: _editNextStep,
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                  color: Ui.surface2,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(Icons.east, size: 15, color: Ui.accent),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: t.nextStep == null || t.nextStep!.isEmpty
                            ? const Text('No next step. Click to write one.', style: TextStyle(color: Ui.faint))
                            : Md(t.nextStep!, selectable: false),
                      ),
                    ],
                  ),
                ),
                if (t.items.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 12, 2, 2),
                    child: Text(
                      'Checklist  $done of ${t.items.length}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Ui.muted),
                    ),
                  ),
                  for (final i in t.items) _ItemRow(app: app, t: t, item: i),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: TextField(
                    controller: _newItem,
                    style: const TextStyle(fontSize: 13),
                    onSubmitted: (_) => _addItem(),
                    decoration: const InputDecoration(
                      hintText: 'Add a checklist point, press Enter',
                      prefixIcon: Icon(Icons.add, size: 16),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                    ),
                  ),
                ),
                Wrap(
                  spacing: 2,
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(() => showFiles = !showFiles),
                      icon: Icon(showFiles ? Icons.expand_less : Icons.description_outlined, size: 15),
                      label: Text(
                        'Files ${files.length}${toReview > 0 ? ', $toReview to review' : ''}',
                        style: TextStyle(color: toReview > 0 ? Ui.warn : null),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => showHistory = !showHistory),
                      icon: Icon(showHistory ? Icons.expand_less : Icons.history, size: 15),
                      label: Text('History ${t.history.length}'),
                    ),
                  ],
                ),
                if (showFiles) ...[
                  if (files.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('No files yet.', style: TextStyle(color: Ui.faint)),
                    ),
                  for (final f in files) _FileRow(app: app, t: t, f: f),
                ],
                if (showHistory)
                  for (final h in t.history.reversed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 56,
                            child: Text(
                              DateTime.tryParse(h.date) == null ? h.date : fmtShort(DateTime.parse(h.date)),
                              style: const TextStyle(fontSize: 12, color: Ui.muted),
                            ),
                          ),
                          Expanded(child: Text(h.text, style: const TextStyle(fontSize: 12.5, height: 1.35))),
                        ],
                      ),
                    ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: ThreadView(app: app, node: taskNode(t), hint: 'task'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final projectLabel = InkWell(
      onTap: () => app.select(projectNode(p)),
      child: Text(p.title, style: const TextStyle(fontSize: 12, color: Ui.muted)),
    );
    final title = InkWell(
      onTap: _rename,
      child: Text(
        t.name,
        style: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          height: 1.25,
          decoration: t.isOpen ? null : TextDecoration.lineThrough,
          color: t.isOpen ? Ui.text : Ui.muted,
        ),
      ),
    );
    final actions = <Widget>[
      PopupMenuButton<TaskStatus>(
        tooltip: 'Change status',
        onSelected: (s) => app.setTaskStatus(t, s),
        itemBuilder: (_) => [
          for (final s in TaskStatus.values)
            PopupMenuItem(
              value: s,
              enabled: s != t.status,
              child: Row(
                children: [
                  Icon(statusIcon(s), size: 15, color: statusColor(s)),
                  const SizedBox(width: 8),
                  Text(s.label),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Chip2(t.status.label, icon: statusIcon(t.status), color: statusColor(t.status), onTap: () {}),
        ),
      ),
      if (AppController.isMobile)
        PopupMenuButton<ImageSource>(
          tooltip: 'Add a photo',
          icon: const Icon(Icons.add_a_photo_outlined, size: 20),
          onSelected: _photo,
          itemBuilder: (_) => const [
            PopupMenuItem(value: ImageSource.camera, child: Text('Take a photo')),
            PopupMenuItem(value: ImageSource.gallery, child: Text('From the gallery')),
          ],
        ),
      if (t.isOpen)
        Padding(
          padding: const EdgeInsets.only(left: 6, top: 2),
          child: AppController.isMobile
              ? IconButton.filled(tooltip: 'Mark done', onPressed: _finish, icon: const Icon(Icons.check, size: 18))
              : FilledButton.icon(onPressed: _finish, icon: const Icon(Icons.check, size: 16), label: const Text('Done')),
        ),
      PopupMenuButton<String>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (v) async {
          switch (v) {
            case 'follow':
              await _followUp();
            case 'folder':
              await SystemIntegration.openPath(t.dir);
            case 'waiting':
              await _editWaiting();
            case 'unplan':
              await app.scheduleTask(t, null);
            case 'nodue':
              await app.editTask(t, {'due': null});
            default:
              if (v.startsWith('p')) await app.editTask(t, {'priority': int.parse(v.substring(1))});
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'follow', child: Text('Create a follow-up task')),
          const PopupMenuItem(value: 'waiting', child: Text('Set who it is waiting on')),
          if (t.scheduled != null) const PopupMenuItem(value: 'unplan', child: Text('Remove from the calendar')),
          if (t.due != null) const PopupMenuItem(value: 'nodue', child: Text('Clear the due date')),
          if (!AppController.isMobile) const PopupMenuItem(value: 'folder', child: Text('Open the task folder')),
          const PopupMenuDivider(),
          for (var i = 1; i <= 5; i++) CheckedPopupMenuItem(value: 'p$i', checked: t.priority == i, child: Text('Priority $i${i == 1 ? ' (highest)' : ''}')),
        ],
      ),
      IconButton(tooltip: 'Close', onPressed: () => app.select('general'), icon: const Icon(Icons.close, size: 18)),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        // On a phone the title gets its own full-width line under the actions.
        if (box.maxWidth < 560) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: projectLabel),
                    ...actions,
                  ],
                ),
                title,
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [projectLabel, const SizedBox(height: 2), title]),
              ),
              const SizedBox(width: 8),
              ...actions,
            ],
          ),
        );
      },
    );
  }

  Widget _facts() {
    final due = t.dueDate;
    final planned = t.scheduledAt;
    final urgent = t.isOpen && due != null && daysUntil(due) <= 1;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Fact(
          icon: Icons.flag_outlined,
          text: due == null ? 'No due date' : 'Due ${fmtDay(due)}, ${relativeDay(due)}',
          color: urgent ? Ui.danger : (due == null ? Ui.faint : Ui.text),
          onTap: _pickDue,
        ),
        _Fact(
          icon: Icons.event,
          text: planned == null ? 'Not planned' : 'Planned ${fmtDay(planned, withTime: t.scheduledHasTime)}',
          color: planned == null ? Ui.faint : Ui.accent,
          onTap: _plan,
        ),
        if (t.waitingOn != null) _Fact(icon: Icons.hourglass_empty, text: 'Waiting on ${t.waitingOn}', color: Ui.warn, onTap: _editWaiting),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text, required this.color, required this.onTap});
  final IconData icon;
  final String text;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: Ui.roundedSmall,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(icon, size: 14, color: color),
              ),
            ),
            TextSpan(text: text),
          ],
        ),
        style: TextStyle(fontSize: 12.5, color: color),
      ),
    ),
  );
}

class _ItemRow extends StatefulWidget {
  const _ItemRow({required this.app, required this.t, required this.item});
  final AppController app;
  final AgendaTask t;
  final Item item;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final due = i.due == null ? null : DateTime.tryParse(i.due!);
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: InkWell(
        onTap: () => widget.app.toggleItem(widget.t, i),
        borderRadius: Ui.roundedSmall,
        child: Row(
          children: [
            SizedBox(
              width: 28,
              height: 26,
              child: Checkbox(value: i.done, onChanged: (_) => widget.app.toggleItem(widget.t, i), visualDensity: VisualDensity.compact),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                i.text,
                style: TextStyle(fontSize: 13, color: i.done ? Ui.muted : Ui.text, decoration: i.done ? TextDecoration.lineThrough : null),
              ),
            ),
            if (due != null && !i.done) Text(fmtShort(due), style: const TextStyle(fontSize: 11.5, color: Ui.muted)),
            SizedBox(
              width: 28,
              child: hover
                  ? IconButton(
                      tooltip: 'Remove',
                      iconSize: 14,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => widget.app.removeTaskItem(widget.t, i),
                      icon: const Icon(Icons.close),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.app, required this.t, required this.f});
  final AppController app;
  final AgendaTask t;
  final TaskFile f;

  @override
  Widget build(BuildContext context) {
    final lower = f.name.toLowerCase();
    final icon = f.isDir
        ? Icons.folder_outlined
        : lower.endsWith('.pdf')
        ? Icons.picture_as_pdf_outlined
        : (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg'))
        ? Icons.image_outlined
        : Icons.description_outlined;
    final review = !f.isDir && f.isText && !f.approved;
    return InkWell(
      onTap: () => app.select(fileNode(t, f)),
      borderRadius: Ui.roundedSmall,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        child: Row(
          children: [
            Icon(icon, size: 15, color: Ui.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(f.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
            if (review) ...[
              Text(f.changedSinceApproval ? 'changed' : 'to review', style: const TextStyle(fontSize: 11.5, color: Ui.warn)),
              TextButton(onPressed: () => app.approveFile(t, f), child: const Text('Approve')),
            ] else if (f.approved)
              const Icon(Icons.check, size: 14, color: Ui.ok),
          ],
        ),
      ),
    );
  }
}

/// The right pane for a project: its status, documents, deadlines and the project chat.
class ProjectPane extends StatelessWidget {
  const ProjectPane({super.key, required this.app, required this.project});
  final AppController app;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final deadlines = [...p.deadlines.where((d) => d.when != null && daysUntil(d.when!) >= 0)]..sort((a, b) => a.date.compareTo(b.date));
    final chats = taskChats(p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(p.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: () => app.select(AppController.newTaskNode(p.id)),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New task'),
              ),
              IconButton(tooltip: 'Close', onPressed: () => app.select('general'), icon: const Icon(Icons.close, size: 18)),
            ],
          ),
        ),
        // Project info stays small so the project chat keeps most of the pane.
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.35),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p.status != null)
                    Text(
                      p.status!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Ui.muted),
                    ),
                  const SizedBox(height: 6),
                  if (chats.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8, bottom: 2),
                      child: Text(
                        'Task chats',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Ui.muted),
                      ),
                    ),
                  for (final (t, last) in chats.take(5))
                    InkWell(
                      onTap: () => app.select(taskNode(t)),
                      borderRadius: Ui.roundedSmall,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            const Icon(Icons.forum_outlined, size: 14, color: Ui.muted),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(t.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                            ),
                            Text(ago(last.at), style: const TextStyle(fontSize: 11.5, color: Ui.faint)),
                          ],
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 2,
                    children: [
                      for (final d in p.docs)
                        TextButton.icon(
                          onPressed: () => SystemIntegration.openPath('${p.dir}/$d'),
                          icon: const Icon(Icons.description_outlined, size: 15),
                          label: Text(d.split('/').last),
                        ),
                      TextButton.icon(
                        onPressed: () => SystemIntegration.openPath(p.dir),
                        icon: const Icon(Icons.folder_open_outlined, size: 15),
                        label: const Text('Folder'),
                      ),
                    ],
                  ),
                  for (final d in deadlines.take(4))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('${fmtDay(d.when!)}: ${d.text}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: daysUntil(d.when!) <= 1 ? Ui.danger : Ui.text)),
                    ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ThreadView(app: app, node: projectNode(p), hint: 'project'),
          ),
        ),
      ],
    );
  }
}

/// The right pane when no task is open: chats across all projects.
class GeneralPane extends StatelessWidget {
  const GeneralPane({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 14, 16, 2),
        child: Text('Across projects', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 16, 10),
        child: Text(
          'Only for things that span several projects. Each project has its own chat in the tabs above.',
          style: TextStyle(fontSize: 12.5, color: Ui.muted),
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: ThreadView(app: app, node: 'general', hint: 'topic', extraSessions: app.otherSessions),
        ),
      ),
    ],
  );
}
