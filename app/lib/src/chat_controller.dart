import 'dart:async';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'thread_context.dart';

/// One conversation thread: its history (read from the Claude transcript, or
/// from the stored conversation when the transcript is gone) plus a live
/// `claude` process for new turns.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.cwd,
    required this.node,
    this.sessionId,
    this.transcriptPath,
    this.stored = const [],
    this.earlier = const [],
    this.model,
    this.systemPrompt,
    this.onSessionStarted,
    this.onMessage,
    this.onTurnFinished,
    this.readOnly = false,
    this.engine,
  });

  /// Makes the chat backend; null means Claude Code (the desktop).
  final ChatEngine Function(String? sessionId)? engine;

  final String cwd;

  /// Tree node this thread belongs to (`task:...`, `project:...`, `general`).
  final String node;
  String? sessionId;
  final String? transcriptPath;

  /// Conversation entries of this session stored in the node's JSON file.
  final List<ConversationEntry> stored;

  /// Stored messages of the node from its other (older) sessions, shown above this one.
  final List<ConversationEntry> earlier;
  final String? model;

  /// Fresh task context for each process start.
  final String Function()? systemPrompt;
  final Future<void> Function(ChatController)? onSessionStarted;
  /// Every user message and every final assistant text, for the stored conversation.
  final Future<void> Function(ChatController, ConversationEntry)? onMessage;

  /// After each turn and after the history loads (e.g. to rescan mentioned files).
  final void Function(ChatController)? onTurnFinished;

  /// Sessions opened only to read (terminal sessions, background runs).
  bool readOnly;

  final items = <ChatItem>[];
  final draft = TextEditingController();
  bool loading = false;
  bool busy = false;
  double costUsd = 0;

  ChatEngine? _claude;
  StreamSubscription<ClaudeEvent>? _sub;
  ChatItem? _streaming;
  final _tools = <String, ChatItem>{};
  RandomAccessFile? _lock;
  Future<void>? _loading;

  /// The user message of the current turn, kept until the session id is known.
  ConversationEntry? _pendingUser;

  Future<void> loadHistory() => _loading ??= _loadHistory();

  Future<void> _loadHistory() async {
    final path = transcriptPath;
    var history = <ChatItem>[];
    if (path == null || !await File(path).exists()) {
      // No transcript: fall back to what the app stored.
      history = _fromStored(stored);
    } else {
      loading = true;
      notifyListeners();
      // Transcripts reach several MB; parse them off the UI isolate.
      history = await compute(readTranscriptSync, path);
      for (final i in history) {
        if (i.role == ChatRole.assistant) i.text = stripMarker(i.text);
      }
      loading = false;
    }
    final all = [..._fromStored(earlier), ...history];
    if (all.isEmpty && path == null) return;
    items.insertAll(0, all);
    notifyListeners();
    onTurnFinished?.call(this);
  }

  static List<ChatItem> _fromStored(List<ConversationEntry> entries) => [
    for (final e in entries) ChatItem(e.role == 'assistant' ? ChatRole.assistant : ChatRole.user, e.text, time: e.at),
  ];

  /// Sends [text], or the draft. [prefix] (e.g. which file this is about) goes in front.
  Future<void> send([String? text, String? prefix]) async {
    final body = (text ?? draft.text).trim();
    if (body.isEmpty || busy || readOnly) return;
    final t = prefix == null ? body : '$prefix\n\n$body';
    draft.clear();
    items.add(ChatItem(ChatRole.user, t, time: DateTime.now()));
    busy = true;
    notifyListeners();
    final entry = ConversationEntry(at: DateTime.now(), role: 'user', text: t, session: sessionId);
    if (sessionId != null) {
      unawaited(onMessage?.call(this, entry));
    } else {
      _pendingUser = entry;
    }
    await _holdLock();
    final claude = _claude ??= engine?.call(sessionId) ?? ClaudeChat(cwd: cwd, sessionId: sessionId, model: model);
    claude.appendSystemPrompt = systemPrompt?.call();
    _sub ??= claude.events.listen(_onEvent);
    await claude.send(t);
  }

  Future<void> stop() async {
    await _claude?.stop();
    _finishTurn(notice: 'Stopped.');
  }

  void _flushPendingUser() {
    final p = _pendingUser;
    if (p == null) return;
    _pendingUser = null;
    unawaited(onMessage?.call(this, ConversationEntry(at: p.at, role: p.role, text: p.text, session: sessionId)));
  }

  void _onEvent(ClaudeEvent e) {
    switch (e) {
      case InitEvent(:final sessionId):
        final isNew = this.sessionId == null;
        this.sessionId = sessionId;
        if (isNew) unawaited(onSessionStarted?.call(this));
        _flushPendingUser();
      case TextDeltaEvent(:final text):
        final s = _streaming;
        if (s == null) {
          items.add(_streaming = ChatItem(ChatRole.assistant, text, time: DateTime.now()));
        } else {
          s.text += text;
        }
      case AssistantTextEvent(:final text):
        final shown = stripMarker(text);
        if (_streaming != null) {
          _streaming!.text = shown;
          _streaming = null;
        } else if (shown.trim().isNotEmpty) {
          items.add(ChatItem(ChatRole.assistant, shown, time: DateTime.now()));
        }
        if (shown.trim().isNotEmpty) {
          unawaited(onMessage?.call(
            this,
            ConversationEntry(at: DateTime.now(), role: 'assistant', text: shown, session: sessionId),
          ));
        }
      case ToolUseEvent():
        _streaming = null;
        final item = ChatItem(ChatRole.tool, e.summary, time: DateTime.now());
        _tools[e.id] = item;
        items.add(item);
      case ToolResultEvent(:final toolUseId, :final text, :final isError):
        final item = _tools[toolUseId];
        if (item != null) {
          item.detail = text.length > 600 ? '${text.substring(0, 600)}...' : text;
          item.isError = isError;
        }
      case ResultEvent(:final isError, :final costUsd, :final text):
        this.costUsd += costUsd ?? 0;
        _flushPendingUser();
        _finishTurn(notice: isError ? 'The turn ended with an error: $text' : null);
        return;
      case ProcessErrorEvent(:final message):
        _flushPendingUser();
        _finishTurn(notice: message);
        return;
    }
    notifyListeners();
  }

  void _finishTurn({String? notice}) {
    _streaming = null;
    busy = false;
    if (notice != null) items.add(ChatItem(ChatRole.notice, notice, isError: true));
    unawaited(_releaseLock());
    notifyListeners();
    onTurnFinished?.call(this);
  }

  /// Tells the background checker a chat is streaming (it defers full runs).
  Future<void> _holdLock() async {
    if (_lock != null) return;
    try {
      await Directory(AgendaPaths.cacheDir).create(recursive: true);
      final raf = await File(AgendaPaths.chatLock).open(mode: FileMode.append);
      await raf.lock(FileLock.blockingExclusive);
      _lock = raf;
    } on FileSystemException {
      // Not fatal: at worst a background run overlaps this chat.
    }
  }

  Future<void> _releaseLock() async {
    final raf = _lock;
    _lock = null;
    if (raf == null) return;
    try {
      await raf.unlock();
      await raf.close();
    } on FileSystemException {
      // already closed
    }
  }

  /// Ends the process and releases resources; the controller is unusable after.
  Future<void> close() async {
    await _sub?.cancel();
    await _claude?.dispose();
    await _releaseLock();
    draft.dispose();
    dispose();
  }
}
