import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'theme.dart';

/// One task on a line: status dot, name, project, the date that matters.
/// Drag it onto a calendar day to plan it.
class TaskRow extends StatelessWidget {
  const TaskRow({super.key, required this.app, required this.p, required this.t, this.showProject = true});
  final AppController app;
  final Project p;
  final AgendaTask t;
  final bool showProject;

  @override
  Widget build(BuildContext context) {
    final selected = app.selected == taskNode(t);
    final row = Material(
      color: selected ? Ui.accentSoft : Colors.transparent,
      borderRadius: Ui.roundedSmall,
      child: InkWell(
        onTap: () => app.select(taskNode(t)),
        borderRadius: Ui.roundedSmall,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: LayoutBuilder(
            builder: (context, box) {
              final icon = Tooltip(
                message: t.status.label,
                child: Icon(statusIcon(t.status), size: 15, color: statusColor(t.status)),
              );
              final name = Text(
                t.name,
                maxLines: box.maxWidth < 480 ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: t.status == TaskStatus.needsUser ? FontWeight.w600 : FontWeight.normal,
                  decoration: t.isOpen ? null : TextDecoration.lineThrough,
                  color: t.isOpen ? Ui.text : Ui.muted,
                ),
              );
              final project = Text(
                p.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Ui.faint),
              );
              if (box.maxWidth < 480) {
                // Phone: name on its own line(s), project and date under it.
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 1), child: icon),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          name,
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (showProject) Expanded(child: project) else const Spacer(),
                              if (t.isOpen) TaskDateLabel(t: t),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  icon,
                  const SizedBox(width: 9),
                  Expanded(child: name),
                  if (showProject) ...[const SizedBox(width: 8), project],
                  if (t.isOpen) ...[const SizedBox(width: 10), TaskDateLabel(t: t)],
                ],
              );
            },
          ),
        ),
      ),
    );
    if (!t.isOpen) return row;
    return AppController.isMobile
        ? LongPressDraggable<AgendaTask>(
            data: t,
            feedback: DragChip(label: t.name, color: statusColor(t.status)),
            child: row,
          )
        : Draggable<AgendaTask>(
            data: t,
            feedback: DragChip(label: t.name, color: statusColor(t.status)),
            childWhenDragging: Opacity(opacity: 0.4, child: row),
            child: row,
          );
  }
}

/// The due date (red when close) or else the planned day of a task.
class TaskDateLabel extends StatelessWidget {
  const TaskDateLabel({super.key, required this.t});
  final AgendaTask t;

  @override
  Widget build(BuildContext context) {
    final due = t.dueDate;
    final planned = t.scheduledAt;
    if (due != null && (planned == null || !due.isAfter(planned))) {
      final urgent = daysUntil(due) <= 1;
      return Tooltip(
        message: 'Due ${relativeDay(due)}',
        child: Text(
          'due ${fmtShort(due)}',
          style: TextStyle(fontSize: 11.5, color: urgent ? Ui.danger : Ui.muted, fontWeight: urgent ? FontWeight.w700 : FontWeight.normal),
        ),
      );
    }
    if (planned != null) {
      return Tooltip(
        message: 'Planned ${relativeDay(planned)}',
        child: Text(
          fmtDay(planned, withTime: t.scheduledHasTime),
          style: const TextStyle(fontSize: 11.5, color: Ui.accent),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// What follows the pointer while a task is dragged.
class DragChip extends StatelessWidget {
  const DragChip({super.key, required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Ui.surface3,
        borderRadius: Ui.roundedSmall,
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5, color: Ui.text),
      ),
    ),
  );
}

/// A small heading with a count.
class GroupTitle extends StatelessWidget {
  const GroupTitle(this.text, this.count, {super.key, this.color = Ui.muted, this.hint});
  final String text;
  final int count;
  final Color color;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
    child: Row(
      children: [
        Text(
          text,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color),
        ),
        const SizedBox(width: 6),
        Text('$count', style: const TextStyle(fontSize: 12, color: Ui.faint)),
        if (hint != null) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hint!,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Ui.faint),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Every open task in one list, grouped by when it matters.
class TaskListView extends StatefulWidget {
  const TaskListView({super.key, required this.app});
  final AppController app;

  @override
  State<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends State<TaskListView> {
  bool showDone = false;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final all = app.visibleTasks.toList();
    final groups = groupTasks(all.where((e) => e.$2.isOpen));
    final done = [
      for (final e in all)
        if (!e.$2.isOpen) e,
    ]..sort((a, b) => (b.$2.lastActivity ?? '').compareTo(a.$2.lastActivity ?? ''));
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      children: [
        for (final (title, color, tasks) in groups)
          if (tasks.isNotEmpty) ...[
            GroupTitle(title, tasks.length, color: color),
            for (final (p, t) in tasks) TaskRow(app: app, p: p, t: t, showProject: app.projectFilter == null),
          ],
        if (groups.every((g) => g.$3.isEmpty))
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nothing open. Well done.', style: TextStyle(color: Ui.muted)),
          ),
        if (done.isNotEmpty) ...[
          InkWell(
            onTap: () => setState(() => showDone = !showDone),
            child: GroupTitle(showDone ? 'Done' : 'Done (show)', done.length, color: Ui.faint),
          ),
          if (showDone)
            for (final (p, t) in done.take(40)) TaskRow(app: app, p: p, t: t, showProject: app.projectFilter == null),
        ],
      ],
    );
  }
}

/// Open tasks by urgency: Needs you, Overdue, Today, This week, Later, No date.
/// A task sits in the first group that fits; its date is the earlier of due and planned.
List<(String, Color, List<(Project, AgendaTask)>)> groupTasks(Iterable<(Project, AgendaTask)> open, {DateTime? now}) {
  final today = dayOf(now ?? DateTime.now());
  final weekEnd = today.add(Duration(days: 8 - today.weekday));
  final needs = <(Project, AgendaTask)>[], overdue = <(Project, AgendaTask)>[], todayL = <(Project, AgendaTask)>[];
  final week = <(Project, AgendaTask)>[], later = <(Project, AgendaTask)>[], none = <(Project, AgendaTask)>[];
  DateTime? when(AgendaTask t) {
    final d = [t.dueDate, t.scheduledAt].whereType<DateTime>().map(dayOf).toList()..sort();
    return d.firstOrNull;
  }

  final sorted = open.toList()
    ..sort((a, b) {
      final wa = when(a.$2), wb = when(b.$2);
      if (wa != null && wb != null && wa != wb) return wa.compareTo(wb);
      if ((wa == null) != (wb == null)) return wa == null ? 1 : -1;
      return taskOrder(a.$2, b.$2);
    });
  for (final e in sorted) {
    final t = e.$2;
    final w = when(t);
    final dueOver = t.dueDate != null && dayOf(t.dueDate!).isBefore(today);
    if (t.status == TaskStatus.needsUser) {
      needs.add(e);
    } else if (dueOver) {
      overdue.add(e);
    } else if (w == null) {
      none.add(e);
    } else if (!w.isAfter(today)) {
      todayL.add(e);
    } else if (w.isBefore(weekEnd)) {
      week.add(e);
    } else {
      later.add(e);
    }
  }
  return [
    ('Needs you', Ui.danger, needs),
    ('Overdue', Ui.danger, overdue),
    ('Today', Ui.accent, todayL),
    ('This week', Ui.text, week),
    ('Later', Ui.muted, later),
    ('No date', Ui.muted, none),
  ];
}
