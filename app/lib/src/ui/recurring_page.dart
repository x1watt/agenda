import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'dialogs.dart';
import 'theme.dart';

/// Recurring topics (e.g. "Campervan") holding recurring items (e.g. "Yearly
/// insurance", "TÜV verification"). Reached from the gear menu.
class RecurringPage extends StatelessWidget {
  const RecurringPage({super.key, required this.app});
  final AppController app;

  Future<void> _newTopic(BuildContext context) async {
    final title = await topicDialog(context);
    if (title == null || title.isEmpty) return;
    await app.addRecurringTopic(title);
  }

  Future<void> _newItem(BuildContext context, RecurringTopic topic) async {
    final tasks = app.visibleTasks.where((e) => e.$2.isOpen).toList();
    final r = await recurringItemDialog(context, topic: topic, tasks: tasks);
    if (r is RecurringItemSave) await app.saveRecurringItem(topic.id, r.item);
  }

  Future<void> _editItem(BuildContext context, RecurringTopic topic, RecurringItem item) async {
    final tasks = app.visibleTasks.where((e) => e.$2.isOpen).toList();
    final r = await recurringItemDialog(context, topic: topic, item: item, tasks: tasks);
    if (r is RecurringItemSave) {
      await app.saveRecurringItem(topic.id, r.item);
    } else if (r is RecurringItemDelete) {
      await app.deleteRecurringItem(topic.id, item.id);
    }
  }

  Future<void> _renameTopic(BuildContext context, RecurringTopic topic) async {
    final title = await topicDialog(context, topic: topic);
    if (title == null || title.isEmpty || title == topic.title) return;
    await app.renameRecurringTopic(topic.id, title);
  }

  Future<void> _deleteTopic(BuildContext context, RecurringTopic topic) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${topic.title}"?'),
        content: Text(topic.items.isEmpty ? 'This topic has no items.' : 'This removes all ${topic.items.length} item(s) in it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ui.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await app.deleteRecurringTopic(topic.id);
  }

  @override
  Widget build(BuildContext context) {
    final topics = app.visibleRecurringTopics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageTitle(
          'Recurring',
          subtitle: 'Things that come back on a schedule and are not a task or event, grouped by topic. '
              'Due items show up on the calendar and get announced the same way as a deadline.',
          actions: [Action2(icon: Icons.add, label: 'New topic', primary: true, onPressed: () => _newTopic(context))],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              if (topics.isEmpty) const EmptyNote('No recurring topics yet.'),
              for (final topic in topics)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Panel(
                    padding: EdgeInsets.zero,
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        shape: const Border(),
                        initiallyExpanded: true,
                        title: Text(topic.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        subtitle: Text('${topic.items.length} item${topic.items.length == 1 ? '' : 's'}', style: const TextStyle(fontSize: 12, color: Ui.muted)),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert, size: 18),
                          onSelected: (v) => v == 'rename' ? _renameTopic(context, topic) : _deleteTopic(context, topic),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('Rename')),
                            PopupMenuItem(value: 'delete', child: Text('Delete topic')),
                          ],
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final item in topic.items) _ItemRow(app: app, topic: topic, item: item, onEdit: () => _editItem(context, topic, item)),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => _newItem(context, topic),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('New item'),
                            ),
                          ),
                        ],
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
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.app, required this.topic, required this.item, required this.onEdit});
  final AppController app;
  final RecurringTopic topic;
  final RecurringItem item;
  final VoidCallback onEdit;

  String get _every => item.every == 1 ? 'every ${item.interval.label}' : 'every ${item.every} ${item.interval.label}s';

  Color get _dueColor {
    final due = item.nextDueDate;
    if (due == null) return Ui.muted;
    final days = due.difference(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)).inDays;
    if (days < 0) return Ui.danger;
    if (days <= 14) return Ui.warn;
    return Ui.muted;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onEdit,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.text, style: const TextStyle(fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(
                  'Due ${fmtDay(item.nextDueDate ?? DateTime.now())} · $_every',
                  style: TextStyle(fontSize: 12, color: _dueColor, fontWeight: _dueColor == Ui.muted ? FontWeight.normal : FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        TextButton.icon(
          onPressed: () => app.markRecurringItemDone(topic.id, item.id),
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Mark done'),
        ),
      ],
    ),
  );
}
