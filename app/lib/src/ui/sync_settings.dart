import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../identity/identity.dart';
import '../secrets.dart';
import '../sync/rns_node.dart' show defaultHubs;
import 'dialogs.dart';
import 'theme.dart';

/// The account and the sync with its other devices (laptops, phones) over Reticulum.
class SyncSettings extends StatelessWidget {
  const SyncSettings({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.sync,
    builder: (context, _) => Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AccountSection(app: app),
          const Divider(height: 24),
          _DevicesSection(app: app),
          const Divider(height: 24),
          _ApiKeyField(app: app, help: 'For Claude on the phone. Kept in accounts/, so every device of the account gets it.'),
        ],
      ),
    ),
  );
}

class _AccountSection extends StatefulWidget {
  const _AccountSection({required this.app});
  final AppController app;

  @override
  State<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<_AccountSection> {
  bool _importing = false;
  final _nsec = TextEditingController();
  String? _message;

  @override
  void dispose() {
    _nsec.dispose();
    super.dispose();
  }

  Future<void> _copyNsec(Identity id) async {
    final ok = await confirmDialog(
      context,
      title: 'Copy the account key?',
      body: 'Anyone with this key gets every file of the agenda, the personal folder and the mail credentials. '
          'Paste it only into agenda on your own devices, then clear the clipboard.',
      action: 'Copy',
    );
    if (!ok) return;
    await Clipboard.setData(ClipboardData(text: id.nsec));
    if (mounted) setState(() => _message = 'Key copied. On the other device: Settings > Use an existing account.');
  }

  Future<void> _import() async {
    final ok = await confirmDialog(
      context,
      title: 'Use this account here?',
      body: 'This device joins the account and syncs with its other devices. '
          'Files already on this device are merged with theirs; nothing is deleted.',
      action: 'Use it',
    );
    if (!ok) return;
    final err = await widget.app.sync.importAccount(_nsec.text);
    if (!mounted) return;
    setState(() {
      _message = err ?? 'Done. This device now looks for the others of the account.';
      if (err == null) {
        _importing = false;
        _nsec.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.app.sync.identity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Account', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        if (id == null)
          Text(widget.app.sync.error ?? 'Loading...', style: const TextStyle(color: Ui.muted))
        else ...[
          SelectableText(id.npub, style: Ui.mono.copyWith(fontSize: 12)),
          const SizedBox(height: 4),
          const Text(
            'Every device with the same account key syncs with the others: on the same network and over the internet.',
            style: TextStyle(fontSize: 12, color: Ui.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(onPressed: () => _copyNsec(id), icon: const Icon(Icons.key, size: 16), label: const Text('Copy the account key')),
              TextButton(onPressed: () => setState(() => _importing = !_importing), child: const Text('Use an existing account')),
            ],
          ),
        ],
        if (_importing) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(controller: _nsec, obscureText: true, decoration: const InputDecoration(hintText: 'nsec1... from another device')),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _import, child: const Text('Use')),
            ],
          ),
        ],
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
      ],
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection({required this.app});
  final AppController app;

  Future<void> _editHubs(BuildContext context) async {
    final sync = app.sync;
    final text = await textDialog(
      context,
      title: 'Reticulum hubs',
      initial: sync.hubs.join('\n'),
      multiline: true,
      hint: 'host:port, one per line. Empty restores the defaults.',
    );
    if (text == null) return;
    final hubs = text.split(RegExp(r'[\s,]+')).where((h) => h.isNotEmpty).toList();
    await sync.setHubs(hubs.isEmpty || hubs.join() == defaultHubs.join() ? null : hubs);
  }

  @override
  Widget build(BuildContext context) {
    final sync = app.sync;
    final node = sync.node;
    final devices = sync.devices.toList()..sort((a, b) => a.name.compareTo(b.name));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sync with my other devices'),
          subtitle: Text(sync.status),
          value: app.settings.syncEnabled,
          onChanged: sync.setEnabled,
        ),
        if (node != null) ...[
          if (devices.isEmpty)
            const Text(
              'No other device seen yet. Install agenda there and use the same account key.',
              style: TextStyle(fontSize: 12, color: Ui.muted),
            ),
          for (final d in devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.devices_other, size: 20),
              title: Text(d.name.isEmpty ? d.id.substring(0, 8) : d.name),
              subtitle: Text([
                'seen ${ago(d.lastSeen)} via ${d.via}',
                if (sync.lastSuccess[d.id] != null) 'synced ${ago(sync.lastSuccess[d.id]!)}',
                if (sync.reports[d.id] case final r?) '$r',
              ].join(' · ')),
            ),
          for (final r in sync.reports.values)
            for (final c in r.conflicts.take(5)) Text(c, style: const TextStyle(fontSize: 12, color: Ui.warn)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: sync.syncing ? null : sync.syncNow,
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('Sync now'),
              ),
              TextButton(onPressed: () => _editHubs(context), child: Text('Hubs (${node.connectedHubs.length}/${sync.hubs.length} connected)')),
            ],
          ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Log', style: TextStyle(fontSize: 13)),
              children: [
                Container(
                  height: 180,
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Ui.codeBg, borderRadius: Ui.roundedSmall),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(node.logLines.join('\n'), style: Ui.mono.copyWith(fontSize: 11)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ApiKeyField extends StatefulWidget {
  const _ApiKeyField({required this.app, required this.help});
  final AppController app;
  final String help;

  @override
  State<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<_ApiKeyField> {
  final _c = TextEditingController();
  String? _current;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final k = await Secrets.apiKey(widget.app.settings);
    if (mounted) setState(() => _current = k);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          k == null ? 'Anthropic API key: not set' : 'Anthropic API key: ${k.substring(0, k.length.clamp(0, 10))}...${k.length > 14 ? k.substring(k.length - 4) : ''}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(widget.help, style: const TextStyle(fontSize: 12, color: Ui.muted)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(controller: _c, obscureText: true, decoration: const InputDecoration(hintText: 'sk-ant-...')),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () async {
                if (_c.text.trim().isEmpty) return;
                await Secrets.setApiKey(widget.app.settings, _c.text);
                _c.clear();
                await _load();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}
