import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Result of the new-task and follow-up dialogs.
class TaskDraft {
  TaskDraft({required this.name, this.due, this.priority = 3, this.nextStep, this.moveOpenItems = false, this.closeOrigin = false});
  final String name;
  final String? due;
  final int priority;
  final String? nextStep;
  final bool moveOpenItems;
  final bool closeOrigin;
}

Future<String?> pickDate(BuildContext context, {String? initial}) async {
  final now = DateTime.now();
  final d = await showDatePicker(
    context: context,
    initialDate: (initial == null ? null : DateTime.tryParse(initial)) ?? now,
    firstDate: DateTime(now.year - 1),
    lastDate: DateTime(now.year + 5),
  );
  return d?.toIso8601String().substring(0, 10);
}

/// Dialog for a new task, or a follow-up of [from].
Future<TaskDraft?> taskDialog(BuildContext context, {required String projectTitle, AgendaTask? from}) {
  final name = TextEditingController();
  final next = TextEditingController();
  String? due;
  var priority = from?.priority ?? 3;
  var moveItems = from != null && from.items.any((i) => !i.done);
  var closeOrigin = false;
  return showDialog<TaskDraft>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(from == null ? 'New task in $projectTitle' : 'Follow-up of "${from.name}"'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'What has to happen?'),
                onSubmitted: (_) => name.text.trim().isEmpty
                    ? null
                    : Navigator.pop(context, TaskDraft(name: name.text.trim(), due: due, priority: priority, nextStep: next.text.trim().isEmpty ? null : next.text.trim(), moveOpenItems: moveItems, closeOrigin: closeOrigin)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: next,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'First step (optional)'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final d = await pickDate(context, initial: due);
                      if (d != null) setState(() => due = d);
                    },
                    icon: const Icon(Icons.event, size: 16),
                    label: Text(due == null ? 'Due date' : fmtDate(DateTime.parse(due!))),
                  ),
                  if (due != null)
                    IconButton(onPressed: () => setState(() => due = null), icon: const Icon(Icons.close, size: 16), tooltip: 'No due date'),
                  const SizedBox(width: 12),
                  const Text('Priority', style: TextStyle(color: Ui.muted)),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: priority,
                    underline: const SizedBox.shrink(),
                    items: [for (var p = 1; p <= 5; p++) DropdownMenuItem(value: p, child: Text('$p'))],
                    onChanged: (v) => setState(() => priority = v ?? 3),
                  ),
                ],
              ),
              if (from != null) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: moveItems,
                  onChanged: from.items.any((i) => !i.done) ? (v) => setState(() => moveItems = v ?? false) : null,
                  title: Text('Move the ${from.items.where((i) => !i.done).length} open items to the follow-up'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: closeOrigin,
                  onChanged: (v) => setState(() => closeOrigin = v ?? false),
                  title: const Text('Mark this task done'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => name.text.trim().isEmpty
                ? null
                : Navigator.pop(context, TaskDraft(name: name.text.trim(), due: due, priority: priority, nextStep: next.text.trim().isEmpty ? null : next.text.trim(), moveOpenItems: moveItems, closeOrigin: closeOrigin)),
            child: Text(from == null ? 'Create' : 'Create follow-up'),
          ),
        ],
      ),
    ),
  );
}

/// One-field text dialog. Returns null when cancelled.
Future<String?> textDialog(BuildContext context, {required String title, String initial = '', bool multiline = false, String? hint}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: c,
          autofocus: true,
          minLines: multiline ? 4 : 1,
          maxLines: multiline ? 12 : 1,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: multiline ? null : (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
      ],
    ),
  );
}

Future<bool> confirmDialog(BuildContext context, {required String title, required String body, String action = 'OK'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 420, child: Text(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> projectDialog(BuildContext context) {
  final id = TextEditingController();
  final title = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('New project'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: title, autofocus: true, decoration: const InputDecoration(hintText: 'Title, e.g. Car insurance')),
            const SizedBox(height: 10),
            TextField(
              controller: id,
              decoration: const InputDecoration(hintText: 'Folder name: letters, digits and - only (e.g. car-insurance)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final folder = id.text.trim().isEmpty ? slugFor(title.text) : id.text.trim();
            if (title.text.trim().isEmpty || !isValidProjectId(folder)) return;
            Navigator.pop(context, '$folder\n${title.text.trim()}');
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

/// Asks for a day and, optionally, a time. Returns `YYYY-MM-DD` or
/// `YYYY-MM-DDTHH:MM`, or null when cancelled.
Future<String?> pickSchedule(BuildContext context, {String? initial}) async {
  final start = initial == null ? null : DateTime.tryParse(initial);
  final day = await pickDate(context, initial: initial?.substring(0, 10));
  if (day == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: start != null && initial!.contains('T') ? TimeOfDay.fromDateTime(start) : const TimeOfDay(hour: 9, minute: 0),
    helpText: 'Time (Cancel for the whole day)',
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
  );
  return time == null ? day : '${day}T${two(time.hour)}:${two(time.minute)}';
}

/// What the event dialog asks the caller to do.
sealed class EventEdit {}

class EventSave extends EventEdit {
  EventSave(this.event);
  final AgendaEvent event;
}

class EventDelete extends EventEdit {}

final _hhmm = RegExp(r'^([01]?\d|2[0-3]):[0-5]\d$');

String? _normTime(String s) {
  final t = s.trim();
  if (t.isEmpty || !_hhmm.hasMatch(t)) return null;
  final parts = t.split(':');
  return '${two(int.parse(parts[0]))}:${parts[1]}';
}

/// New event on [date], or edit [event]. [tasks] are offered as an optional link.
Future<EventEdit?> eventDialog(
  BuildContext context, {
  AgendaEvent? event,
  DateTime? date,
  required List<(Project, AgendaTask)> tasks,
}) {
  final title = TextEditingController(text: event?.title ?? '');
  final time = TextEditingController(text: event?.time ?? '');
  final end = TextEditingController(text: event?.end ?? '');
  final note = TextEditingController(text: event?.note ?? '');
  var day = event?.date ?? isoDay(date ?? DateTime.now());
  var task = event?.task;
  String? error;
  return showDialog<EventEdit>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void save() {
          if (title.text.trim().isEmpty) return setState(() => error = 'Give it a title.');
          final t = _normTime(time.text);
          final e = _normTime(end.text);
          if (time.text.trim().isNotEmpty && t == null || end.text.trim().isNotEmpty && e == null) {
            return setState(() => error = 'Times are HH:MM, e.g. 14:30.');
          }
          final linked = task == null ? null : tasks.where((x) => x.$2.uid == task).firstOrNull;
          Navigator.pop(
            context,
            EventSave(AgendaEvent(
              id: event?.id ?? '',
              date: day,
              time: t,
              end: t == null ? null : e,
              title: title.text.trim(),
              note: note.text.trim().isEmpty ? null : note.text.trim(),
              task: task,
              project: linked?.$1.id ?? event?.project,
            )),
          );
        }

        return AlertDialog(
          title: Text(event == null ? 'New event' : 'Event'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: title,
                  autofocus: true,
                  decoration: InputDecoration(hintText: 'What, e.g. Dentist appointment', errorText: error),
                  onSubmitted: (_) => save(),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await pickDate(context, initial: day);
                        if (d != null) setState(() => day = d);
                      },
                      icon: const Icon(Icons.event, size: 16),
                      label: Text(fmtDay(DateTime.parse(day))),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(width: 90, child: TextField(controller: time, decoration: const InputDecoration(hintText: 'From'), onSubmitted: (_) => save())),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('to', style: TextStyle(color: Ui.muted))),
                    SizedBox(width: 90, child: TextField(controller: end, decoration: const InputDecoration(hintText: 'Until'), onSubmitted: (_) => save())),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: tasks.any((x) => x.$2.uid == task) ? task : null,
                  isExpanded: true,
                  decoration: const InputDecoration(hintText: 'Linked task (optional)'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('No linked task')),
                    for (final (p, t) in tasks) DropdownMenuItem<String?>(value: t.uid, child: Text('${t.name}  (${p.title})', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => task = v),
                ),
                const SizedBox(height: 10),
                TextField(controller: note, minLines: 2, maxLines: 5, decoration: const InputDecoration(hintText: 'Note: address, what to bring (optional)')),
              ],
            ),
          ),
          actions: [
            if (event != null)
              TextButton(
                onPressed: () => Navigator.pop(context, EventDelete()),
                style: TextButton.styleFrom(foregroundColor: Ui.danger),
                child: const Text('Delete'),
              ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: save, child: const Text('Save')),
          ],
        );
      },
    ),
  );
}

/// New recurring topic, or rename [topic]. Returns the title, or null when cancelled.
Future<String?> topicDialog(BuildContext context, {RecurringTopic? topic}) {
  final title = TextEditingController(text: topic?.title ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(topic == null ? 'New recurring topic' : 'Rename topic'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: title,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Title, e.g. Campervan'),
          onSubmitted: (_) => Navigator.pop(context, title.text.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => title.text.trim().isEmpty ? null : Navigator.pop(context, title.text.trim()),
          child: Text(topic == null ? 'Create' : 'Save'),
        ),
      ],
    ),
  );
}

/// What the recurring-item dialog asks the caller to do.
sealed class RecurringItemEdit {}

class RecurringItemSave extends RecurringItemEdit {
  RecurringItemSave(this.item);
  final RecurringItem item;
}

class RecurringItemDelete extends RecurringItemEdit {}

/// New item under [topic], or edit [item]. [tasks] are offered as an optional link.
Future<RecurringItemEdit?> recurringItemDialog(
  BuildContext context, {
  required RecurringTopic topic,
  RecurringItem? item,
  required List<(Project, AgendaTask)> tasks,
}) {
  final text = TextEditingController(text: item?.text ?? '');
  final note = TextEditingController(text: item?.note ?? '');
  final everyCtrl = TextEditingController(text: '${item?.every ?? 1}');
  var interval = item?.interval ?? RecurringInterval.yearly;
  var every = item?.every ?? 1;
  var anchor = item?.anchor ?? isoDay(DateTime.now());
  var task = item?.task;
  String? error;
  return showDialog<RecurringItemEdit>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void save() {
          if (text.text.trim().isEmpty) return setState(() => error = 'Give it a name.');
          final linked = task == null ? null : tasks.where((x) => x.$2.uid == task).firstOrNull;
          final base = RecurringItem(
            id: item?.id ?? '',
            text: text.text.trim(),
            interval: interval,
            every: every,
            anchor: anchor,
            nextDue: item?.nextDue ?? anchor,
            lastDone: item?.lastDone,
            note: note.text.trim().isEmpty ? null : note.text.trim(),
            project: linked?.$1.id ?? item?.project,
            task: task,
            history: item?.history ?? const [],
          );
          Navigator.pop(context, RecurringItemSave(base));
        }

        return AlertDialog(
          title: Text(item == null ? 'New item in ${topic.title}' : 'Recurring item'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: text,
                  autofocus: true,
                  decoration: InputDecoration(hintText: 'What, e.g. Yearly insurance', errorText: error),
                  onSubmitted: (_) => save(),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<RecurringInterval>(
                        initialValue: interval,
                        decoration: const InputDecoration(hintText: 'Repeats'),
                        items: [
                          for (final i in RecurringInterval.values)
                            DropdownMenuItem(value: i, child: Text('Every ${every == 1 ? '' : '$every '}${i.label}${every == 1 ? '' : 's'}')),
                        ],
                        onChanged: (v) => setState(() => interval = v ?? RecurringInterval.yearly),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 70,
                      child: TextField(
                        controller: everyCtrl,
                        decoration: const InputDecoration(hintText: 'Every'),
                        keyboardType: TextInputType.number,
                        onChanged: (v) => setState(() => every = int.tryParse(v)?.clamp(1, 999) ?? 1),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text('First due', style: TextStyle(color: Ui.muted, fontSize: 12.5)),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await pickDate(context, initial: anchor);
                        if (d != null) setState(() => anchor = d);
                      },
                      icon: const Icon(Icons.event, size: 16),
                      label: Text(fmtDay(DateTime.parse(anchor))),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: tasks.any((x) => x.$2.uid == task) ? task : null,
                  isExpanded: true,
                  decoration: const InputDecoration(hintText: 'Linked task (optional)'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('No linked task')),
                    for (final (p, t) in tasks) DropdownMenuItem<String?>(value: t.uid, child: Text('${t.name}  (${p.title})', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => task = v),
                ),
                const SizedBox(height: 10),
                TextField(controller: note, minLines: 2, maxLines: 5, decoration: const InputDecoration(hintText: 'Note (optional)')),
              ],
            ),
          ),
          actions: [
            if (item != null)
              TextButton(
                onPressed: () => Navigator.pop(context, RecurringItemDelete()),
                style: TextButton.styleFrom(foregroundColor: Ui.danger),
                child: const Text('Delete'),
              ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: save, child: const Text('Save')),
          ],
        );
      },
    ),
  );
}
