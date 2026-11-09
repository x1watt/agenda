import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'theme.dart';

class RunsPage extends StatelessWidget {
  const RunsPage({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageTitle(
          'Background runs',
          subtitle: 'Checks run at login and every ${app.settings.intervalMinutes} minutes. Claude is woken only after '
              'a boot, for the daily review, for new mail from a watched sender, for a deadline in the next '
              '24 hours, or when you press Run now.',
          actions: [
            Action2(icon: app.runInProgress ? Icons.sync : Icons.play_arrow, label: app.runInProgress ? 'Running' : 'Run now', primary: true, onPressed: app.runInProgress ? null : app.runNow),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              if (app.runs.isEmpty) const EmptyNote('No runs yet.'),
              for (final r in app.runs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Panel(
                    padding: EdgeInsets.zero,
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        shape: const Border(),
                        leading: r.ended == null
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(r.ok ? Icons.check_circle_outline : Icons.error_outline, color: r.ok ? Ui.ok : Ui.danger),
                        title: Text('${fmtDateTime(r.started)}  ${r.reasons.join('; ')}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                        subtitle: Text(
                          [
                            if (r.ended != null) '${r.ended!.difference(r.started).inSeconds} s',
                            if (r.costUsd != null) '\$${r.costUsd!.toStringAsFixed(2)}',
                            if (r.timedOut) 'timed out',
                            if (r.error != null) r.error!,
                          ].join(', '),
                          style: const TextStyle(fontSize: 12, color: Ui.muted),
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Md(r.summary ?? (r.ended == null ? 'In progress...' : 'No summary.')),
                          if (r.sessionId != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(onPressed: () => app.openSession(r.sessionId!), icon: const Icon(Icons.forum_outlined, size: 16), label: const Text('Open conversation')),
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
