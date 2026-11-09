import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'theme.dart';

/// Photos or files shared from another app: pick the task they belong to.
class SharePage extends StatefulWidget {
  const SharePage({super.key, required this.app});
  final AppController app;

  @override
  State<SharePage> createState() => _SharePageState();
}

class _SharePageState extends State<SharePage> {
  String query = '';
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final n = app.pendingShares.length;
    final q = query.toLowerCase();
    final tasks = [
      for (final e in app.agenda?.allTasks ?? const <(Project, AgendaTask)>[])
        if (e.$2.isOpen && (q.isEmpty || e.$2.name.toLowerCase().contains(q) || e.$1.title.toLowerCase().contains(q))) e,
    ]..sort((a, b) => taskOrder(a.$2, b.$2));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            n == 0 ? 'Nothing to add.' : 'Add ${n == 1 ? 'this file' : 'these $n files'} to which task?',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search tasks', prefixIcon: Icon(Icons.search, size: 18)),
            onChanged: (v) => setState(() => query = v),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              for (final (p, t) in tasks)
                ListTile(
                  enabled: !busy && n > 0,
                  leading: Icon(statusIcon(t.status), color: statusColor(t.status), size: 20),
                  title: Text(t.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(p.title),
                  onTap: () async {
                    setState(() => busy = true);
                    final added = await app.addSharesToTask(t);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$added file${added == 1 ? '' : 's'} added to "${t.name}". They reach your other devices with the next sync.')),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
