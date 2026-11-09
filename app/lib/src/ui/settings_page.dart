import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../system_integration.dart';
import 'sync_settings.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});
  final AppController app;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _model = TextEditingController(text: widget.app.settings.model ?? '');
  String? _mailTest;
  bool _testing = false;

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _testMail() async {
    setState(() {
      _testing = true;
      _mailTest = null;
    });
    String result;
    try {
      final mail = await BridgeMail.connect(widget.app.paths.accountsDir);
      final folders = await mail.folders();
      await mail.close();
      result = 'Connected: ${folders.length} folders.';
    } on Object catch (e) {
      result = 'Failed: $e';
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _mailTest = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final s = app.settings;
    final t = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        const Text('Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const Caption('Account and devices'),
        SyncSettings(app: app),
        if (!AppController.isMobile) ...[
          const Caption('Start and background'),
          Panel(
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Start the app at login'),
                  subtitle: const Text('Starts hidden in the tray; open it from the dock or the tray icon.'),
                  value: app.autostartOn,
                  onChanged: (v) => app.setAutostart(v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Background checks'),
                  subtitle: Text(
                    app.timerOn
                        ? 'On. Next check ${app.nextCheck == null ? 'soon' : 'at ${fmtTime(app.nextCheck!)}'}. '
                              'Runs even when this window is closed.'
                        : 'Off. Claude only works when you chat.',
                  ),
                  value: app.timerOn,
                  onChanged: (v) => app.setBackgroundChecks(v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Check every'),
                  subtitle: const Text('A check is cheap; Claude is only woken when something needs it.'),
                  trailing: DropdownButton<int>(
                    value: const [15, 30, 60, 120, 180].contains(s.intervalMinutes) ? s.intervalMinutes : 30,
                    items: [
                      for (final m in const [15, 30, 60, 120, 180]) DropdownMenuItem(value: m, child: Text(m < 60 ? '$m minutes' : '${m ~/ 60} h')),
                    ],
                    onChanged: (v) => v == null ? null : app.setInterval(v),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Daily review after'),
                  subtitle: const Text('The first check at or after this hour runs a full review.'),
                  trailing: DropdownButton<int>(
                    value: s.dailyRunHour,
                    items: [for (var h = 5; h <= 12; h++) DropdownMenuItem(value: h, child: Text('${two(h)}:00'))],
                    onChanged: (v) {
                      if (v == null) return;
                      s.dailyRunHour = v;
                      app.saveSettings();
                    },
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Desktop notifications'),
                  subtitle: const Text('After a run that needs you, finds new mail, or fails.'),
                  value: s.notifications,
                  onChanged: (v) {
                    s.notifications = v;
                    app.saveSettings();
                  },
                ),
              ],
            ),
          ),
          const Caption('Claude'),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: 'Model',
                    helperText: 'Empty uses the Claude Code default. Examples: opus, sonnet, haiku.',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (v) {
                    s.model = v.trim().isEmpty ? null : v.trim();
                    app.saveSettings();
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'Chats and background runs use full permissions (bypass), as chosen. Background runs are told '
                  'not to send mail or contact anyone; they put such steps under "Needs you".',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => SystemIntegration.openPath(app.paths.reviewPrompt),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('Edit review prompt'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => SystemIntegration.openPath(app.paths.agendaDir),
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('Open agenda folder'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Caption('Mail'),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.bridgeUp ? 'Proton Mail Bridge is running on 127.0.0.1:1143.' : 'Proton Mail Bridge is not running.'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton(onPressed: _testing ? null : _testMail, child: Text(_testing ? 'Testing...' : 'Test mail connection')),
                    const SizedBox(width: 12),
                    if (_mailTest != null) Expanded(child: Text(_mailTest!)),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text('Settings file: ${AgendaPaths.settingsFile}', style: t.textTheme.bodySmall),
      ],
    );
  }
}
