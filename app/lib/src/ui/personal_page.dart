import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../system_integration.dart';
import 'theme.dart';

/// Read-only view of the personal-information folder (~/personal): the
/// Markdown files on the left, the chosen one rendered on the right.
class PersonalPage extends StatefulWidget {
  const PersonalPage({super.key, required this.app});
  final AppController app;

  @override
  State<PersonalPage> createState() => _PersonalPageState();
}

class _PersonalPageState extends State<PersonalPage> {
  /// Paths relative to the folder, README first.
  List<String> files = const [];
  String? current;
  String? text;
  int openQuestions = 0;
  String? error;

  String get dir => widget.app.personalDir;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final root = Directory(dir);
    if (!await root.exists()) {
      setState(() => error = 'No personal folder at $dir yet.');
      return;
    }
    final found = <String>[
      await for (final e in root.list(recursive: true))
        if (e is File && e.path.endsWith('.md')) e.path.substring(dir.length + 1),
    ];
    int rank(String f) => f == 'README.md' ? 0 : (f == 'open-questions.md' ? 1 : (f.contains('/') ? 3 : 2));
    found.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.compareTo(b);
    });
    var questions = 0;
    final oq = File('$dir/open-questions.md');
    if (await oq.exists()) {
      questions = RegExp(r'^\d+\. ', multiLine: true).allMatches(await oq.readAsString()).length;
    }
    if (!mounted) return;
    setState(() {
      files = found;
      openQuestions = questions;
      error = null;
    });
    await _open(current != null && found.contains(current) ? current! : (found.firstOrNull ?? ''));
  }

  Future<void> _open(String rel) async {
    if (rel.isEmpty) return;
    String content;
    try {
      content = await File('$dir/$rel').readAsString();
    } on FileSystemException catch (e) {
      content = 'Cannot read $rel: ${e.message}';
    }
    if (!mounted) return;
    setState(() {
      current = rel;
      text = content;
    });
  }

  /// Links between the files open here; anything else opens externally.
  void _link(String href) {
    if (href.startsWith('http')) {
      SystemIntegration.openPath(href);
      return;
    }
    final base = current == null || !current!.contains('/') ? '' : current!.substring(0, current!.lastIndexOf('/') + 1);
    var target = Uri.parse('$base$href').normalizePath().path;
    if (target.endsWith('/')) target = '${target}README.md';
    if (files.contains(target)) {
      _open(target);
    } else {
      SystemIntegration.openPath('$dir/$target');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageTitle(
          'Personal info',
          subtitle: 'Identity, family, IDs, bank accounts, contacts and documents in one place ($dir). '
              'Tasks read it first and keep it up to date. Read-only here; edit the files directly or ask Claude.',
          actions: [
            Action2(icon: Icons.refresh, label: 'Reload', onPressed: _load),
            if (current != null) Action2(icon: Icons.edit_outlined, label: 'Open in editor', onPressed: () => SystemIntegration.openPath('$dir/$current')),
            Action2(icon: Icons.folder_open_outlined, label: 'Folder', onPressed: () => SystemIntegration.openPath(dir)),
          ],
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(24), child: Text(error!, style: const TextStyle(color: Ui.muted)))
        else
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 230,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
                    children: [
                      for (final f in files)
                        Material(
                          color: f == current ? Ui.accentSoft : Colors.transparent,
                          borderRadius: Ui.roundedSmall,
                          child: InkWell(
                            onTap: () => _open(f),
                            borderRadius: Ui.roundedSmall,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _label(f),
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 13, fontWeight: f == current ? FontWeight.w600 : FontWeight.normal),
                                    ),
                                  ),
                                  if (f == 'open-questions.md' && openQuestions > 0) Badge2(openQuestions, color: Ui.warn),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(),
                Expanded(
                  child: text == null
                      ? const SizedBox.shrink()
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                          children: [Md(text!, onLink: _link)],
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _label(String rel) {
    const names = {
      'README.md': 'Overview',
      'open-questions.md': 'Open questions',
      'me.md': 'Me',
      'family.md': 'Family',
      'ids.md': 'IDs and documents',
      'money.md': 'Bank and income',
      'tax.md': 'Tax',
      'health.md': 'Health',
      'vehicles.md': 'Vehicles',
      'contacts.md': 'Contacts',
      'documents/README.md': 'Document copies',
    };
    return names[rel] ?? rel.replaceAll('.md', '');
  }
}
