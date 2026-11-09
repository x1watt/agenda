import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'dialogs.dart';
import 'task_list_view.dart';
import 'theme.dart';

/// Week or month calendar: events, tasks planned on a day, due dates and
/// project deadlines. Drop a task on a day to plan it there. Below it, what
/// needs you and the open tasks that have no day yet.
class CalendarView extends StatelessWidget {
  const CalendarView({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final open = app.visibleTasks.where((e) => e.$2.isOpen).toList();
    final needs = [...open.where((e) => e.$2.status == TaskStatus.needsUser)]..sort((a, b) => taskOrder(a.$2, b.$2));
    final unplanned = [...open.where((e) => e.$2.status != TaskStatus.needsUser && e.$2.scheduled == null && e.$2.due == null)]
      ..sort((a, b) => taskOrder(a.$2, b.$2));
    final days = _visibleDays(app.calendarAnchor, app.monthView);
    final data = _collect(app, days.first, days.last);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CalendarBar(app: app, days: days),
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
            child: LayoutBuilder(
              builder: (context, box) => app.monthView
                  ? _MonthGrid(app: app, days: days, data: data)
                  : box.maxWidth < 600
                  ? _WeekList(app: app, days: days, data: data)
                  : _WeekRow(app: app, days: days, data: data),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Divider(),
        Expanded(
          flex: 2,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              GroupTitle('Needs you', needs.length, color: Ui.danger),
              if (needs.isEmpty) const _Hint('Nothing is waiting on you.'),
              for (final (p, t) in needs) TaskRow(app: app, p: p, t: t, showProject: app.projectFilter == null),
              GroupTitle('No date yet', unplanned.length, hint: 'drag onto a day to plan it'),
              if (unplanned.isEmpty) const _Hint('Every open task has a day.'),
              for (final (p, t) in unplanned) TaskRow(app: app, p: p, t: t, showProject: app.projectFilter == null),
            ],
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
    child: Text(text, style: const TextStyle(fontSize: 12.5, color: Ui.faint)),
  );
}

/// The 7 days of the anchor's week (Monday first), or the 6 weeks around its month.
List<DateTime> _visibleDays(DateTime anchor, bool month) {
  final a = dayOf(anchor);
  if (!month) {
    final monday = a.subtract(Duration(days: a.weekday - 1));
    return [for (var i = 0; i < 7; i++) DateTime(monday.year, monday.month, monday.day + i)];
  }
  final first = DateTime(a.year, a.month, 1);
  final start = first.subtract(Duration(days: first.weekday - 1));
  return [for (var i = 0; i < 42; i++) DateTime(start.year, start.month, start.day + i)];
}

/// Everything on one day of the calendar.
class _Day {
  final events = <AgendaEvent>[];
  final planned = <(Project, AgendaTask)>[];
  final due = <(Project, AgendaTask)>[];
  final deadlines = <Deadline>[];
  final recurring = <(RecurringTopic, RecurringItem)>[];

  int get count => events.length + planned.length + due.length + deadlines.length + recurring.length;
}

Map<String, _Day> _collect(AppController app, DateTime from, DateTime to) {
  final out = <String, _Day>{};
  bool inRange(DateTime d) => !dayOf(d).isBefore(from) && !dayOf(d).isAfter(to);
  _Day at(DateTime d) => out.putIfAbsent(isoDay(d), _Day.new);
  for (final e in app.visibleEvents) {
    if (e.day != null && inRange(e.day!)) at(e.day!).events.add(e);
  }
  for (final (p, t) in app.visibleTasks) {
    final s = t.scheduledAt;
    if (s != null && inRange(s)) at(s).planned.add((p, t));
    final d = t.dueDate;
    if (t.isOpen && d != null && inRange(d) && !(s != null && sameDay(s, d))) at(d).due.add((p, t));
  }
  for (final p in app.agenda?.projects ?? const <Project>[]) {
    if (app.projectFilter != null && p.id != app.projectFilter) continue;
    for (final d in p.deadlines) {
      if (d.when != null && inRange(d.when!)) at(d.when!).deadlines.add(d);
    }
  }
  for (final topic in app.visibleRecurringTopics) {
    for (final item in topic.items) {
      final d = item.nextDueDate;
      if (d != null && inRange(d)) at(d).recurring.add((topic, item));
    }
  }
  for (final day in out.values) {
    day.planned.sort((a, b) {
      final ta = a.$2.scheduledHasTime ? a.$2.scheduled! : '~';
      final tb = b.$2.scheduledHasTime ? b.$2.scheduled! : '~';
      final c = ta.compareTo(tb);
      return c != 0 ? c : taskOrder(a.$2, b.$2);
    });
  }
  return out;
}

class _CalendarBar extends StatelessWidget {
  const _CalendarBar({required this.app, required this.days});
  final AppController app;
  final List<DateTime> days;

  @override
  Widget build(BuildContext context) {
    final a = app.calendarAnchor;
    final first = days.first, last = days.last;
    final range = first.month == last.month
        ? '${first.day} to ${last.day} ${monthNames[last.month - 1]} ${last.year}'
        : '${first.day} ${monthNames[first.month - 1].substring(0, 3)} to ${last.day} ${monthNames[last.month - 1].substring(0, 3)} ${last.year}';
    final title = app.monthView ? '${monthNames[a.month - 1]} ${a.year}' : 'KW ${isoWeek(first)}:  $range';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
      child: Row(
        children: [
          IconButton(tooltip: app.monthView ? 'Previous month' : 'Previous week', onPressed: () => app.moveCalendar(-1), icon: const Icon(Icons.chevron_left)),
          TextButton(onPressed: () => app.moveCalendar(0), child: const Text('Today')),
          IconButton(tooltip: app.monthView ? 'Next month' : 'Next week', onPressed: () => app.moveCalendar(1), icon: const Icon(Icons.chevron_right)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: false, label: Text('Week')),
              ButtonSegment(value: true, label: Text('Month')),
            ],
            selected: {app.monthView},
            onSelectionChanged: (s) => app.setMonthView(s.first),
          ),
        ],
      ),
    );
  }
}

/// Width of the calendar-week column in the month grid.
const _kwWidth = 30.0;

/// Keeps the time of day of a planned task when it moves to another day.
String _moveTo(AgendaTask t, DateTime day) => t.scheduledHasTime ? '${isoDay(day)}T${t.scheduled!.substring(11, 16)}' : isoDay(day);

Future<void> _newEvent(BuildContext context, AppController app, DateTime day) async {
  final r = await eventDialog(context, date: day, tasks: app.visibleTasks.where((e) => e.$2.isOpen).toList());
  if (r is EventSave) await app.saveEvent(r.event);
}

Future<void> _editEvent(BuildContext context, AppController app, AgendaEvent e) async {
  final r = await eventDialog(
    context,
    event: e,
    tasks: (app.agenda?.allTasks ?? const <(Project, AgendaTask)>[]).where((x) => x.$2.isOpen || x.$2.uid == e.task).toList(),
  );
  switch (r) {
    case EventSave(:final event):
      await app.saveEvent(event);
    case EventDelete():
      await app.deleteEvent(e);
    case null:
  }
}

Future<void> _editRecurring(BuildContext context, AppController app, RecurringTopic topic, RecurringItem item) async {
  final r = await recurringItemDialog(
    context,
    topic: topic,
    item: item,
    tasks: (app.agenda?.allTasks ?? const <(Project, AgendaTask)>[]).where((x) => x.$2.isOpen || x.$2.uid == item.task).toList(),
  );
  switch (r) {
    case RecurringItemSave(item: final updated):
      await app.saveRecurringItem(topic.id, updated);
    case RecurringItemDelete():
      await app.deleteRecurringItem(topic.id, item.id);
    case null:
  }
}

/// A day that accepts dropped tasks.
class _DropDay extends StatelessWidget {
  const _DropDay({required this.app, required this.day, required this.builder});
  final AppController app;
  final DateTime day;
  final Widget Function(bool hot) builder;

  @override
  Widget build(BuildContext context) => DragTarget<AgendaTask>(
    onWillAcceptWithDetails: (d) => d.data.scheduledAt == null || !sameDay(d.data.scheduledAt!, day),
    onAcceptWithDetails: (d) => app.scheduleTask(d.data, _moveTo(d.data, day)),
    builder: (context, candidates, _) => builder(candidates.isNotEmpty),
  );
}

class _WeekRow extends StatelessWidget {
  const _WeekRow({required this.app, required this.days, required this.data});
  final AppController app;
  final List<DateTime> days;
  final Map<String, _Day> data;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final d in days)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: _DropDay(
              app: app,
              day: d,
              builder: (hot) => _DayBox(app: app, day: d, data: data[isoDay(d)], hot: hot, compact: false),
            ),
          ),
        ),
    ],
  );
}

/// The week as a vertical list of days, for phones.
class _WeekList extends StatelessWidget {
  const _WeekList({required this.app, required this.days, required this.data});
  final AppController app;
  final List<DateTime> days;
  final Map<String, _Day> data;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.zero,
    children: [
      for (final d in days)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _DropDay(
            app: app,
            day: d,
            builder: (hot) => _DayRow(app: app, day: d, data: data[isoDay(d)], hot: hot),
          ),
        ),
    ],
  );
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.app, required this.day, required this.data, required this.hot});
  final AppController app;
  final DateTime day;
  final _Day? data;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    final today = sameDay(day, DateTime.now());
    final entries = <Widget>[
      if (data != null) ...[
        for (final e in data!.events) _EventEntry(app: app, e: e, compact: true),
        for (final (p, t) in data!.planned) _TaskEntry(app: app, p: p, t: t, compact: true),
        for (final (p, t) in data!.due) _TaskEntry(app: app, p: p, t: t, compact: true, due: true),
        for (final dl in data!.deadlines) _DeadlineEntry(app: app, d: dl, compact: true),
        for (final (topic, item) in data!.recurring) _RecurringEntry(app: app, topic: topic, item: item, compact: true),
      ],
    ];
    return InkWell(
      onLongPress: () => _newEvent(context, app, day),
      borderRadius: Ui.roundedSmall,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 3),
        decoration: BoxDecoration(
          color: hot ? Ui.accentSoft : (today ? Ui.surface2 : Ui.surface),
          borderRadius: Ui.roundedSmall,
          border: Border.all(color: hot || today ? Ui.accent : Ui.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 58,
              child: Text(
                '${weekdayNames[day.weekday - 1]} ${day.day}',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: today ? Ui.accent : Ui.muted),
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.only(bottom: 3),
                      child: Text(' ', style: TextStyle(fontSize: 12)),
                    )
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: entries),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.app, required this.days, required this.data});
  final AppController app;
  final List<DateTime> days;
  final Map<String, _Day> data;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          const SizedBox(width: _kwWidth),
          for (final n in weekdayNames)
            Expanded(
              child: Center(
                child: Text(
                  n,
                  style: const TextStyle(fontSize: 11.5, color: Ui.muted, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 4),
      for (var w = 0; w < 6; w++)
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _kwWidth,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Tooltip(
                    message: 'Calendar week ${isoWeek(days[w * 7])}',
                    child: Text(
                      'KW\n${isoWeek(days[w * 7])}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: days.sublist(w * 7, w * 7 + 7).any((d) => sameDay(d, DateTime.now())) ? Ui.accent : Ui.faint,
                      ),
                    ),
                  ),
                ),
              ),
              for (final d in days.sublist(w * 7, w * 7 + 7))
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(1.5),
                    child: _DropDay(
                      app: app,
                      day: d,
                      builder: (hot) => Opacity(
                        opacity: d.month == app.calendarAnchor.month ? 1 : 0.45,
                        child: _DayBox(app: app, day: d, data: data[isoDay(d)], hot: hot, compact: true),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
}

class _DayBox extends StatefulWidget {
  const _DayBox({required this.app, required this.day, required this.data, required this.hot, required this.compact});
  final AppController app;
  final DateTime day;
  final _Day? data;
  final bool hot;
  final bool compact;

  @override
  State<_DayBox> createState() => _DayBoxState();
}

class _DayBoxState extends State<_DayBox> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final d = widget.day;
    final data = widget.data;
    final today = sameDay(d, DateTime.now());
    final past = dayOf(d).isBefore(dayOf(DateTime.now()));
    final entries = <Widget>[
      if (data != null) ...[
        for (final e in data.events) _EventEntry(app: app, e: e, compact: widget.compact),
        for (final (p, t) in data.planned) _TaskEntry(app: app, p: p, t: t, compact: widget.compact),
        for (final (p, t) in data.due) _TaskEntry(app: app, p: p, t: t, compact: widget.compact, due: true),
        for (final dl in data.deadlines) _DeadlineEntry(app: app, d: dl, compact: widget.compact),
        for (final (topic, item) in data.recurring) _RecurringEntry(app: app, topic: topic, item: item, compact: widget.compact),
      ],
    ];
    final header = Row(
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: today ? BoxDecoration(color: Ui.accent, borderRadius: BorderRadius.circular(999)) : null,
            child: Text(
              widget.compact ? '${d.day}' : '${weekdayNames[d.weekday - 1]} ${d.day}',
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: today ? Ui.bg : (past ? Ui.faint : Ui.muted)),
            ),
          ),
        ),
        const Spacer(),
        if (hover)
          InkWell(
            onTap: () => _newEvent(context, app, d),
            borderRadius: Ui.roundedSmall,
            child: const Tooltip(
              message: 'New event on this day',
              child: Icon(Icons.add, size: 15, color: Ui.accent),
            ),
          ),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => _newEvent(context, app, d),
        child: Container(
          padding: EdgeInsets.all(widget.compact ? 3 : 5),
          decoration: BoxDecoration(
            color: widget.hot ? Ui.accentSoft : (today ? Ui.surface2 : Ui.surface),
            borderRadius: Ui.roundedSmall,
            border: Border.all(color: widget.hot || today ? Ui.accent : Ui.border, width: today && !widget.hot ? 1 : 1),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              // Month cells show what fits and then "+n".
              if (widget.compact) {
                final fit = ((box.maxHeight - 20) / 18).floor().clamp(0, 99);
                final shown = entries.length > fit ? entries.take((fit - 1).clamp(0, 99)).toList() : entries;
                // Very small cells clip instead of overflowing.
                return ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    maxHeight: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        const SizedBox(height: 2),
                        ...shown,
                        if (shown.length < entries.length)
                          InkWell(
                            onTap: () {
                              app.calendarAnchor = d;
                              app.setMonthView(false);
                            },
                            child: Text('+${entries.length - shown.length} more', style: const TextStyle(fontSize: 11, color: Ui.muted)),
                          ),
                      ],
                    ),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView(padding: EdgeInsets.zero, children: entries),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A coloured bar with text: the look shared by every calendar entry.
class _Entry extends StatelessWidget {
  const _Entry({
    required this.color,
    required this.text,
    required this.compact,
    this.onTap,
    this.tooltip,
    this.faded = false,
    this.bold = false,
    this.fill = false,
  });
  final Color color;
  final String text;
  final bool compact;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool faded;
  final bool bold;

  /// Tinted background (events); tasks only get the bar.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      margin: const EdgeInsets.only(bottom: 3),
      padding: EdgeInsets.fromLTRB(5, compact ? 1 : 3, 4, compact ? 1 : 3),
      decoration: BoxDecoration(
        color: fill ? color.withValues(alpha: 0.16) : Ui.surface3.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Text(
        text,
        maxLines: compact ? 1 : 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: compact ? 11 : 11.5,
          height: 1.25,
          color: faded ? Ui.faint : Ui.text,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
          decoration: faded ? TextDecoration.lineThrough : null,
        ),
      ),
    );
    final tapped = InkWell(onTap: onTap, borderRadius: BorderRadius.circular(4), child: body);
    return tooltip == null ? tapped : Tooltip(message: tooltip!, child: tapped);
  }
}

class _EventEntry extends StatelessWidget {
  const _EventEntry({required this.app, required this.e, required this.compact});
  final AppController app;
  final AgendaEvent e;
  final bool compact;

  @override
  Widget build(BuildContext context) => _Entry(
    color: Ui.purple,
    fill: true,
    compact: compact,
    text: '${e.time == null ? '' : '${e.time} '}${e.title}',
    tooltip: [
      '${e.time ?? 'All day'}${e.end == null ? '' : ' to ${e.end}'}: ${e.title}',
      if (e.note != null) e.note!,
      if (e.task != null) 'Task: ${app.agenda?.taskByUid(e.task!)?.$2.name ?? e.task}',
    ].join('\n'),
    onTap: () => _editEvent(context, app, e),
  );
}

class _RecurringEntry extends StatelessWidget {
  const _RecurringEntry({required this.app, required this.topic, required this.item, required this.compact});
  final AppController app;
  final RecurringTopic topic;
  final RecurringItem item;
  final bool compact;

  @override
  Widget build(BuildContext context) => _Entry(
    color: Ui.ok,
    fill: true,
    compact: compact,
    text: '${topic.title}: ${item.text}',
    tooltip: [
      '${topic.title}: ${item.text}',
      'Every ${item.every == 1 ? '' : '${item.every} '}${item.interval.label}${item.every == 1 ? '' : 's'}',
      if (item.note != null) item.note!,
      if (item.task != null) 'Task: ${app.agenda?.taskByUid(item.task!)?.$2.name ?? item.task}',
    ].join('\n'),
    onTap: () => _editRecurring(context, app, topic, item),
  );
}

class _TaskEntry extends StatelessWidget {
  const _TaskEntry({required this.app, required this.p, required this.t, required this.compact, this.due = false});
  final AppController app;
  final Project p;
  final AgendaTask t;
  final bool compact;

  /// Shown on its due date (not planned that day).
  final bool due;

  @override
  Widget build(BuildContext context) {
    final time = !due && t.scheduledHasTime ? '${t.scheduled!.substring(11, 16)} ' : '';
    final entry = _Entry(
      color: due ? Ui.danger : statusColor(t.status),
      compact: compact,
      text: '${due ? 'Due: ' : ''}$time${t.name}',
      faded: !t.isOpen,
      bold: t.status == TaskStatus.needsUser || app.selected == taskNode(t),
      tooltip: '${t.name}\n${p.title}, ${t.status.label}${t.dueDate == null ? '' : ', due ${fmtDay(t.dueDate!)}'}',
      onTap: () => app.select(taskNode(t)),
    );
    if (!t.isOpen) return entry;
    return AppController.isMobile
        ? LongPressDraggable<AgendaTask>(
            data: t,
            feedback: DragChip(label: t.name, color: statusColor(t.status)),
            child: entry,
          )
        : Draggable<AgendaTask>(
            data: t,
            feedback: DragChip(label: t.name, color: statusColor(t.status)),
            childWhenDragging: Opacity(opacity: 0.35, child: entry),
            child: entry,
          );
  }
}

class _DeadlineEntry extends StatelessWidget {
  const _DeadlineEntry({required this.app, required this.d, required this.compact});
  final AppController app;
  final Deadline d;
  final bool compact;

  @override
  Widget build(BuildContext context) => _Entry(
    color: Ui.warn,
    fill: true,
    compact: compact,
    text: 'Deadline: ${d.text}',
    tooltip: '${app.agenda?.projectById(d.project ?? '')?.title ?? ''} deadline: ${d.text}',
    onTap: d.task == null ? () => app.select('project:${d.project}') : () => app.select('task:${d.task}'),
  );
}
