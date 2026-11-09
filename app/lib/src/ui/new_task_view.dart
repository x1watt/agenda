import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import 'dialogs.dart';
import 'theme.dart';

/// Composer for a new task: title, what needs to be done, due date and priority
/// on the left; on the right the first message to Claude. Sending it (or
/// pressing Create) creates the task and opens its page with the conversation.
class NewTaskView extends StatefulWidget {
  const NewTaskView({super.key, required this.app, required this.project});
  final AppController app;
  final Project project;

  @override
  State<NewTaskView> createState() => _NewTaskViewState();
}

class _NewTaskViewState extends State<NewTaskView> {
  final _title = TextEditingController();
  final _what = TextEditingController();
  final _message = TextEditingController();
  final _titleFocus = FocusNode();
  String? _due;
  String? _scheduled;
  int _priority = 3;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _what.dispose();
    _message.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  Future<void> _create({String? message}) async {
    final name = _title.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the task a title first.');
      _titleFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.app.createTask(
      widget.project,
      name: name,
      due: _due,
      scheduled: _scheduled,
      priority: _priority,
      nextStep: _what.text.trim().isEmpty ? null : _what.text.trim(),
      firstMessage: message,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent &&
        (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final m = _message.text.trim();
    if (m.isEmpty || _busy) return;
    _create(message: m);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final p = widget.project;
    final form = ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 20, 24),
      children: [
        TextField(
          controller: _title,
          focusNode: _titleFocus,
          autofocus: true,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            hintText: 'Title: what has to happen?',
            hintStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Ui.faint),
            errorText: _error,
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip2(
              _due == null ? 'No due date' : 'Due ${fmtDate(DateTime.parse(_due!))}, ${relativeDay(DateTime.parse(_due!))}',
              icon: Icons.event,
              color: Ui.muted,
              menu: false,
              onTap: () async {
                final d = await pickDate(context, initial: _due);
                if (d != null) setState(() => _due = d);
              },
            ),
            if (_due != null)
              IconButton(tooltip: 'Clear the due date', iconSize: 15, visualDensity: VisualDensity.compact, onPressed: () => setState(() => _due = null), icon: const Icon(Icons.close)),
            Chip2(
              _scheduled == null ? 'Not planned' : 'Planned ${fmtDay(DateTime.parse(_scheduled!), withTime: _scheduled!.contains('T'))}',
              icon: Icons.calendar_month,
              color: _scheduled == null ? Ui.muted : Ui.accent,
              menu: false,
              onTap: () async {
                final s = await pickSchedule(context, initial: _scheduled);
                if (s != null) setState(() => _scheduled = s);
              },
            ),
            if (_scheduled != null)
              IconButton(tooltip: 'Not planned', iconSize: 15, visualDensity: VisualDensity.compact, onPressed: () => setState(() => _scheduled = null), icon: const Icon(Icons.close)),
            PopupMenuButton<int>(
              tooltip: 'Priority',
              onSelected: (v) => setState(() => _priority = v),
              itemBuilder: (_) => [for (var i = 1; i <= 5; i++) PopupMenuItem(value: i, child: Text('Priority $i${i == 1 ? ' (highest)' : ''}'))],
              child: Chip2('P$_priority', icon: Icons.flag_outlined, color: _priority == 1 ? Ui.warn : Ui.muted, onTap: () {}),
            ),
            Chip2('Project: ${p.title}', icon: Icons.folder_outlined, color: Ui.faint),
          ],
        ),
        const Caption('What needs to be done'),
        TextField(
          controller: _what,
          minLines: 6,
          maxLines: 16,
          style: const TextStyle(fontSize: 13, height: 1.45),
          decoration: const InputDecoration(
            hintText: 'The situation, what the outcome should be, anything Claude should know. '
                'This becomes the task\'s next step; you can split it into items later.',
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _create(),
              icon: const Icon(Icons.add, size: 16),
              label: Text(_busy ? 'Creating...' : 'Create task'),
            ),
            TextButton(onPressed: app.back, child: const Text('Cancel')),
            const Text('or write to Claude to create it and start the conversation', style: TextStyle(fontSize: 12, color: Ui.faint)),
          ],
        ),
      ],
    );

    final chat = Container(
      decoration: BoxDecoration(color: Ui.surface, borderRadius: Ui.rounded, border: Border.all(color: Ui.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Ui.border))),
            child: const Row(
              children: [
                Icon(Icons.forum_outlined, size: 15, color: Ui.accent),
                SizedBox(width: 8),
                Text('Conversation', style: TextStyle(fontSize: 12.5, color: Ui.muted)),
              ],
            ),
          ),
          Expanded(
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: Text(
                _title.text.trim().isEmpty
                    ? 'Give the task a title, then tell Claude what you need: research, a draft, a plan, a phone number. '
                        'Your first message creates the task and starts the conversation.'
                    : 'Your first message creates "${_title.text.trim()}" and starts the conversation. '
                        'Claude gets the title and what needs to be done automatically.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Ui.muted, height: 1.45),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: Ui.border))),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: _onKey,
                    child: TextField(
                      controller: _message,
                      minLines: 1,
                      maxLines: 8,
                      style: const TextStyle(fontSize: 13),
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(hintText: 'Write to Claude about this task. Enter sends, Shift+Enter for a new line.'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 36,
                  width: 36,
                  child: IconButton.filled(
                    onPressed: _busy ? null : _send,
                    tooltip: 'Create the task and send',
                    style: IconButton.styleFrom(backgroundColor: Ui.accent, foregroundColor: Ui.bg),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > 900;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 16, 6),
              child: Row(
                children: [
                  IconButton(tooltip: 'Back', onPressed: app.back, icon: const Icon(Icons.arrow_back)),
                  const SizedBox(width: 4),
                  Text(p.title, style: const TextStyle(color: Ui.muted, fontSize: 13)),
                  const Text('  /  ', style: TextStyle(color: Ui.faint)),
                  const Text('New task', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 11, child: form),
                        const VerticalDivider(),
                        Expanded(flex: 9, child: Padding(padding: const EdgeInsets.fromLTRB(0, 0, 12, 12), child: chat)),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(flex: 3, child: form),
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
}
