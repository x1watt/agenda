import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../secrets.dart';
import '../sync_service.dart';
import 'theme.dart';

/// Settings for the LAN sync: pairing on the desktop, pairing and status on the phone.
class SyncSettings extends StatelessWidget {
  const SyncSettings({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.sync,
    builder: (context, _) => Panel(child: SyncService.isServer ? _Desktop(app: app) : _Phone(app: app)),
  );
}

class _Desktop extends StatefulWidget {
  const _Desktop({required this.app});
  final AppController app;

  @override
  State<_Desktop> createState() => _DesktopState();
}

class _DesktopState extends State<_Desktop> {
  List<String> addresses = const [];

  @override
  void initState() {
    super.initState();
    widget.app.sync.lanAddresses().then((a) => mounted ? setState(() => addresses = a) : null);
  }

  @override
  Widget build(BuildContext context) {
    final sync = widget.app.sync;
    final server = sync.server;
    final code = server?.pairingCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sync with the phone over the home network'),
          subtitle: Text(
            server != null
                ? 'On, at ${addresses.isEmpty ? 'this computer' : addresses.join(', ')} port ${server.boundPort}. '
                      'Syncs the projects, events and ~/personal. Credentials in accounts/ stay here.'
                : (sync.serverError ?? 'Off.'),
          ),
          value: widget.app.settings.syncEnabled,
          onChanged: sync.setServerEnabled,
        ),
        if (server != null) ...[
          const SizedBox(height: 8),
          if (code != null)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Ui.accentSoft, borderRadius: Ui.rounded),
              child: Row(
                children: [
                  Text(code, style: Ui.mono.copyWith(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 4)),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Text('Open agenda on the phone > Settings > Pair with desktop and enter this code. Valid for 5 minutes.'),
                  ),
                ],
              ),
            )
          else
            OutlinedButton.icon(onPressed: sync.startPairing, icon: const Icon(Icons.phonelink_setup), label: const Text('Pair a phone')),
          const SizedBox(height: 10),
          for (final d in server.devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.smartphone),
              title: Text(d.name),
              subtitle: Text('Paired ${fmtDate(d.paired)}${d.lastSeen == null ? '' : ', last sync ${ago(d.lastSeen!)}'}'),
              trailing: TextButton(onPressed: () => sync.revoke(d), child: const Text('Remove')),
            ),
        ],
        const Divider(height: 24),
        _ApiKeyField(app: widget.app, help: 'Used by Claude in the phone app. Stored in accounts/; the phone picks it up at its next sync.'),
      ],
    );
  }
}

class _Phone extends StatefulWidget {
  const _Phone({required this.app});
  final AppController app;

  @override
  State<_Phone> createState() => _PhoneState();
}

class _PhoneState extends State<_Phone> {
  final _host = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _host.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    setState(() {
      _busy = true;
      _message = 'Looking for the desktop...';
    });
    final found = await widget.app.sync.discover();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (found.isEmpty) {
        _message = 'No desktop answered. Is the agenda app open there, and is the phone on the same Wi-Fi? You can also type its address.';
      } else {
        _host.text = found.first.host;
        _message = 'Found ${found.first.name} at ${found.first.host}.';
      }
    });
  }

  Future<void> _pair() async {
    setState(() => _busy = true);
    final err = await widget.app.sync.pair(_host.text.trim(), _code.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = err ?? 'Paired. The first sync is running.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final sync = widget.app.sync;
    final peer = sync.peer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (peer != null) ...[
          Text('Paired with ${peer.name} (${peer.host})', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(sync.status ?? 'Not synced yet.', style: const TextStyle(color: Ui.muted)),
          if (sync.lastReport != null && sync.lastReport!.conflicts.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final c in sync.lastReport!.conflicts.take(5)) Text(c, style: const TextStyle(fontSize: 12, color: Ui.warn)),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(onPressed: sync.syncing ? null : sync.syncNow, icon: const Icon(Icons.sync, size: 16), label: const Text('Sync now')),
              TextButton(onPressed: sync.unpair, child: const Text('Unpair')),
            ],
          ),
        ] else ...[
          const Text('Pair with the desktop', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('On the desktop: Settings > Pair a phone. Both must be on the same Wi-Fi.', style: TextStyle(color: Ui.muted)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: TextField(controller: _host, decoration: const InputDecoration(labelText: 'Desktop address'))),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _busy ? null : _find, child: const Text('Find')),
            ],
          ),
          const SizedBox(height: 8),
          TextField(controller: _code, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Code shown on the desktop')),
          const SizedBox(height: 8),
          FilledButton(onPressed: _busy ? null : _pair, child: const Text('Pair')),
        ],
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
        const Divider(height: 24),
        _ApiKeyField(app: widget.app, help: 'For Claude on the phone. Comes from the desktop when pairing; you can also paste one here.'),
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
