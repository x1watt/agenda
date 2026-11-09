import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../chat_controller.dart';
import 'theme.dart';

/// The one conversation about a node: all its messages, the input box.
class ThreadView extends StatelessWidget {
  const ThreadView({
    super.key,
    required this.app,
    required this.node,
    required this.hint,
    this.extraSessions,
    this.prefix,
  });
  final AppController app;
  final String node;
  final String hint;

  /// For General: sessions that are not chats of a node (terminal, runs) to open here.
  final List<SessionInfo>? extraSessions;

  /// Put in front of every message sent from here (e.g. which file it is about).
  final String? prefix;

  @override
  Widget build(BuildContext context) {
    final chat = app.chatFor(node);
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) => Container(
        decoration: BoxDecoration(color: Ui.surface, borderRadius: Ui.rounded, border: Border.all(color: Ui.border)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            if (!chat.readOnly && (extraSessions?.isNotEmpty ?? false)) _SessionsBar(app: app, sessions: extraSessions!),
            Expanded(child: _Messages(chat: chat, hint: hint)),
            if (chat.readOnly)
              _ReadOnlyBar(app: app)
            else
              _InputBox(key: ValueKey(chat), chat: chat, hint: hint, prefix: prefix),
          ],
        ),
      ),
    );
  }
}

/// General only: a menu with the sessions that are not chats of a node
/// (terminal conversations, background runs), opened read-only.
class _SessionsBar extends StatelessWidget {
  const _SessionsBar({required this.app, required this.sessions});
  final AppController app;
  final List<SessionInfo> sessions;

  @override
  Widget build(BuildContext context) => Container(
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    alignment: Alignment.centerRight,
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Ui.border))),
    child: PopupMenuButton<String>(
      tooltip: 'Terminal sessions and background runs',
      onSelected: app.openSession,
      itemBuilder: (_) => [
        for (final s in sessions.take(30))
          PopupMenuItem(value: s.id, child: Text('${s.title}  (${ago(s.lastActivity)})', style: const TextStyle(fontSize: 13))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history, size: 15, color: Ui.muted),
            const SizedBox(width: 4),
            Text('Other sessions ${sessions.length}', style: const TextStyle(fontSize: 12, color: Ui.muted)),
          ],
        ),
      ),
    ),
  );
}

class _Messages extends StatelessWidget {
  const _Messages({required this.chat, required this.hint});
  final ChatController chat;
  final String hint;

  @override
  Widget build(BuildContext context) {
    if (chat.loading) return const Center(child: CircularProgressIndicator());
    final items = chat.items;
    if (items.isEmpty && !chat.busy) {
      return Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Text(
          'No messages yet. Write below; Claude gets the details of this $hint automatically.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Ui.muted),
        ),
      );
    }
    // Group consecutive tool lines under the Claude message they belong to.
    final blocks = <_Block>[];
    for (final i in items) {
      if (i.role == ChatRole.tool && blocks.isNotEmpty && blocks.last.role == ChatRole.assistant) {
        blocks.last.tools.add(i);
      } else if (i.role == ChatRole.tool) {
        blocks.add(_Block(ChatRole.assistant, null, i.time)..tools.add(i));
      } else if (i.role == ChatRole.assistant && blocks.isNotEmpty && blocks.last.role == ChatRole.assistant) {
        blocks.last.texts.add(i.text);
      } else {
        blocks.add(_Block(i.role, i.text, i.time, isError: i.isError));
      }
    }
    return SelectionArea(
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        itemCount: blocks.length + (chat.busy ? 1 : 0),
        itemBuilder: (context, i) {
          if (chat.busy && i == 0) return const _Working();
          final b = blocks[blocks.length - 1 - (i - (chat.busy ? 1 : 0))];
          return _BlockView(block: b);
        },
      ),
    );
  }
}

class _Block {
  _Block(this.role, String? text, this.time, {this.isError = false}) {
    if (text != null) texts.add(text);
  }
  final ChatRole role;
  final DateTime? time;
  final bool isError;
  final texts = <String>[];
  final tools = <ChatItem>[];
}

class _BlockView extends StatelessWidget {
  const _BlockView({required this.block});
  final _Block block;

  @override
  Widget build(BuildContext context) {
    final b = block;
    if (b.role == ChatRole.notice) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (b.isError ? Ui.danger : Ui.warn).withValues(alpha: 0.1),
          borderRadius: Ui.roundedSmall,
        ),
        child: Text(b.texts.join('\n'), style: TextStyle(fontSize: 12.5, color: b.isError ? Ui.danger : Ui.warn)),
      );
    }
    final isUser = b.role == ChatRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: EdgeInsets.fromLTRB(isUser ? 40 : 0, 4, isUser ? 0 : 40, 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
        decoration: BoxDecoration(
          color: isUser ? Ui.accentSoft : Ui.surface2,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isUser ? 12 : 3),
            bottomRight: Radius.circular(isUser ? 3 : 12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(isUser ? 'You' : 'Claude', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11.5, color: isUser ? Ui.accent : Ui.muted)),
                if (b.time != null) ...[
                  const SizedBox(width: 8),
                  Text(fmtDateTime(b.time!), style: const TextStyle(fontSize: 11, color: Ui.faint)),
                ],
              ],
            ),
            const SizedBox(height: 4),
            if (b.tools.isNotEmpty) _Tools(tools: b.tools),
            for (final t in b.texts) if (isUser) Text(t, style: const TextStyle(fontSize: 13, height: 1.4)) else Md(t, selectable: false),
          ],
        ),
      ),
    );
  }
}

/// Tool calls, collapsed to one line with a count; expands to the list.
class _Tools extends StatefulWidget {
  const _Tools({required this.tools});
  final List<ChatItem> tools;

  @override
  State<_Tools> createState() => _ToolsState();
}

class _ToolsState extends State<_Tools> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    final mono = Ui.mono.copyWith(fontSize: 11.5, color: Ui.muted);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => open = !open),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(open ? Icons.expand_more : Icons.chevron_right, size: 14, color: Ui.muted),
                Flexible(
                  child: Text(
                    open ? 'Actions' : '${tools.length} action${tools.length == 1 ? '' : 's'}: ${tools.last.text}',
                    style: mono,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (open)
            for (final t in tools)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 1),
                child: Tooltip(
                  message: t.detail ?? '',
                  child: Text(t.text, style: mono.copyWith(color: t.isError ? Ui.danger : Ui.muted)),
                ),
              ),
        ],
      ),
    );
  }
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Row(
      children: [
        SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 8),
        Text('Claude is working...', style: TextStyle(color: Ui.muted, fontSize: 12.5)),
      ],
    ),
  );
}

/// Shown under a terminal session or background run opened in General.
class _ReadOnlyBar extends StatelessWidget {
  const _ReadOnlyBar({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: const BoxDecoration(color: Ui.surface2, border: Border(top: BorderSide(color: Ui.border))),
    child: Row(
      children: [
        const Icon(Icons.visibility_outlined, size: 16, color: Ui.muted),
        const SizedBox(width: 8),
        const Expanded(child: Text('A session from outside the app. Read only.', style: TextStyle(fontSize: 12.5))),
        Action2(icon: Icons.close, label: 'Back', onPressed: app.closeSession),
      ],
    ),
  );
}

class _InputBox extends StatefulWidget {
  const _InputBox({super.key, required this.chat, required this.hint, this.prefix});
  final ChatController chat;
  final String hint;
  final String? prefix;

  @override
  State<_InputBox> createState() => _InputBoxState();
}

class _InputBoxState extends State<_InputBox> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent &&
        (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      widget.chat.send(null, widget.prefix);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Ui.border))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: chat.draft,
                focusNode: _focus,
                minLines: 1,
                maxLines: 8,
                style: const TextStyle(fontSize: 13),
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(hintText: 'Write about this ${widget.hint}. Enter sends, Shift+Enter for a new line.'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 36,
            width: 36,
            child: chat.busy
                ? IconButton.outlined(onPressed: chat.stop, tooltip: 'Stop', icon: const Icon(Icons.stop, size: 18))
                : IconButton.filled(
                    onPressed: () => chat.send(null, widget.prefix),
                    tooltip: 'Send',
                    style: IconButton.styleFrom(backgroundColor: Ui.accent, foregroundColor: Ui.bg),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
          ),
        ],
      ),
    );
  }
}
