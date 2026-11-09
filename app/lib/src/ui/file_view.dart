import 'dart:async';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../chat_controller.dart';
import '../system_integration.dart';
import '../task_files.dart';
import 'theme.dart';
import 'thread_view.dart';

/// A file of a task: preview or editor, review actions, and the task's
/// conversation on the right (messages are marked as about this file).
class FileView extends StatefulWidget {
  const FileView({super.key, required this.app, required this.project, required this.task, required this.file});
  final AppController app;
  final Project project;
  final AgendaTask task;
  final TaskFile file;

  @override
  State<FileView> createState() => _FileViewState();
}

class _FileViewState extends State<FileView> {
  static const _maxBytes = 2 * 1024 * 1024;

  final _editor = TextEditingController();
  String? _saved; // content on disk as last loaded or saved
  String? _error;
  bool _editing = false;
  bool _saving = false;
  StreamSubscription<FileSystemEvent>? _watch;
  ChatController? _chat;
  bool _chatWasBusy = false;

  TaskFile get f => widget.file;
  bool get _dirty => _saved != null && _editor.text != _saved;

  @override
  void initState() {
    super.initState();
    _editor.addListener(() => setState(() {}));
    unawaited(_load());
    // Reload when the file changes on disk (Claude edited it, or another editor), unless
    // there are unsaved edits here. Editors often replace files, so watch the folder.
    if (!f.isDir) {
      try {
        _watch = File(f.path).parent.watch().listen((e) {
          if (e.path == f.path && !_dirty && !_saving) unawaited(_load());
        });
      } on FileSystemException {
        // no watching; the Reload button still works
      }
    }
    _chat = widget.app.chatFor(taskNode(widget.task))..addListener(_onChat);
  }

  // After Claude finishes a turn in this thread, show its edits right away.
  void _onChat() {
    final busy = _chat?.busy ?? false;
    if (_chatWasBusy && !busy && !_dirty) unawaited(_load());
    _chatWasBusy = busy;
  }

  @override
  void dispose() {
    _watch?.cancel();
    _chat?.removeListener(_onChat);
    _editor.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (f.isDir || !f.isText) return;
    try {
      final file = File(f.path);
      if (await file.length() > _maxBytes) {
        setState(() => _error = 'This file is too large to show here. Open it externally.');
        return;
      }
      final text = await file.readAsString();
      if (!mounted) return;
      setState(() {
        _saved = text;
        _error = null;
        if (_editor.text != text) _editor.text = text;
      });
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _error = 'Cannot read the file: ${e.message}');
    } on FormatException {
      if (mounted) setState(() => _error = 'This file is not plain text. Open it externally.');
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.app.saveFile(f, _editor.text);
    if (!mounted) return;
    setState(() {
      _saved = _editor.text;
      _saving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final p = widget.project;
    final t = widget.task;
    final canEdit = f.isText && _error == null && _saved != null;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > 900;
        final chat = ThreadView(
          app: app,
          node: taskNode(t),
          hint: 'file',
          prefix: 'About the file ${f.rel} (task ${t.uid} "${t.name}"):',
        );
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _status(),
                  Text('Modified ${fmtDateTime(f.modified)}', style: const TextStyle(fontSize: 12, color: Ui.muted)),
                  SelectableText(f.rel, style: Ui.mono.copyWith(fontSize: 11.5, color: Ui.faint)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Wrap(
                spacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (canEdit) ...[
                    Action2(icon: _editing ? Icons.visibility_outlined : Icons.edit_outlined, label: _editing ? 'Preview' : 'Edit', onPressed: () => setState(() => _editing = !_editing)),
                    Action2(icon: Icons.save_outlined, label: _saving ? 'Saving...' : 'Save', onPressed: _dirty && !_saving ? _save : null),
                    Action2(icon: Icons.undo, label: 'Revert', onPressed: _dirty ? () => _editor.text = _saved! : null),
                  ],
                  if (!f.isDir && f.isText)
                    Action2(
                      icon: Icons.verified_outlined,
                      label: f.approved ? 'Approved' : 'Approve',
                      primary: !f.approved && !_dirty,
                      tooltip: _dirty ? 'Save your changes first' : 'Mark this file as reviewed and OK',
                      onPressed: f.approved || _dirty ? null : () => app.approveFile(t, f),
                    ),
                  Action2(icon: Icons.open_in_new, label: 'Open externally', onPressed: () => SystemIntegration.openPath(f.path)),
                  if (!f.isDir) Action2(icon: Icons.folder_open_outlined, label: 'Folder', onPressed: () => SystemIntegration.openPath(File(f.path).parent.path)),
                  Action2(icon: Icons.refresh, label: 'Reload', onPressed: _dirty ? null : _load),
                  if (_dirty) const Padding(padding: EdgeInsets.only(left: 8), child: Text('Unsaved changes', style: TextStyle(color: Ui.warn, fontSize: 12.5))),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: ClipRRect(borderRadius: Ui.rounded, child: _body()),
              ),
            ),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 16, 4),
              child: Row(
                children: [
                  IconButton(tooltip: 'Back to the task', onPressed: () => app.select(taskNode(t)), icon: const Icon(Icons.arrow_back)),
                  const SizedBox(width: 4),
                  InkWell(onTap: () => app.select(projectNode(p)), child: Text(p.title, style: const TextStyle(color: Ui.muted, fontSize: 13))),
                  const Text('  /  ', style: TextStyle(color: Ui.faint)),
                  InkWell(onTap: () => app.select(taskNode(t)), child: Text(t.name, style: const TextStyle(color: Ui.muted, fontSize: 13), overflow: TextOverflow.ellipsis)),
                  const Text('  /  ', style: TextStyle(color: Ui.faint)),
                  Expanded(child: Text(f.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 3, child: body),
                        const VerticalDivider(),
                        Expanded(flex: 2, child: Padding(padding: const EdgeInsets.fromLTRB(0, 0, 12, 12), child: chat)),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(flex: 3, child: body),
                        const Divider(),
                        Expanded(flex: 2, child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: chat)),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _status() {
    if (f.isDir) return const Chip2('Folder', icon: Icons.folder_outlined);
    if (!f.isText) return const Chip2('Binary file', icon: Icons.insert_drive_file_outlined);
    if (f.approved) {
      return Chip2('Approved ${f.ref?.when == null ? '' : fmtDateTime(f.ref!.when!)}', icon: Icons.verified_outlined, color: Ui.ok);
    }
    if (f.changedSinceApproval) return const Chip2('Changed after you approved it', icon: Icons.rate_review_outlined, color: Ui.warn);
    return const Chip2('Not reviewed yet', icon: Icons.rate_review_outlined, color: Ui.warn);
  }

  Widget _body() {
    if (f.isDir) return _FolderList(path: f.path);
    if (const {'jpg', 'jpeg', 'png', 'webp', 'gif'}.contains(f.name.split('.').last.toLowerCase())) {
      return Container(
        color: Ui.codeBg,
        child: InteractiveViewer(maxScale: 6, child: Center(child: Image.file(File(f.path), fit: BoxFit.contain, cacheWidth: 2400))),
      );
    }
    if (!f.isText) {
      return const _Centered('No preview for this file type. Use "Open externally".');
    }
    if (_error != null) return _Centered(_error!);
    if (_saved == null) return const Center(child: CircularProgressIndicator());
    if (_editing) {
      return Container(
        color: Ui.codeBg,
        child: TextField(
          controller: _editor,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: Ui.mono.copyWith(fontSize: 13, height: 1.45, color: Ui.text),
          decoration: const InputDecoration(
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.all(16),
          ),
        ),
      );
    }
    return Container(
      color: Ui.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
        child: f.isMarkdown
            ? Md(_editor.text, size: 13.5)
            : SelectableText(_editor.text, style: Ui.mono.copyWith(fontSize: 13, height: 1.45)),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    color: Ui.surface,
    alignment: Alignment.center,
    padding: const EdgeInsets.all(24),
    child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Ui.muted)),
  );
}

/// Lists a folder's files; each opens with the desktop's default program.
class _FolderList extends StatelessWidget {
  const _FolderList({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<FileSystemEntity>>(
    future: Directory(path).list().toList(),
    builder: (context, snap) {
      final items = [...?snap.data]..sort((a, b) => a.path.compareTo(b.path));
      return Container(
        color: Ui.surface,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            for (final e in items)
              InkWell(
                onTap: () => SystemIntegration.openPath(e.path),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Icon(e is Directory ? Icons.folder_outlined : Icons.insert_drive_file_outlined, size: 16, color: Ui.muted),
                      const SizedBox(width: 8),
                      Expanded(child: Text(e.path.split('/').last)),
                      const Icon(Icons.open_in_new, size: 14, color: Ui.muted),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
