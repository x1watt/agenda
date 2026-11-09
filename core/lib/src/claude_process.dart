import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// Events distilled from `claude -p --output-format stream-json --verbose`.
sealed class ClaudeEvent {
  const ClaudeEvent();
}

class InitEvent extends ClaudeEvent {
  const InitEvent(this.sessionId, this.model);
  final String sessionId;
  final String? model;
}

/// A streamed piece of assistant text (only with --include-partial-messages).
class TextDeltaEvent extends ClaudeEvent {
  const TextDeltaEvent(this.text);
  final String text;
}

/// A complete assistant text block; supersedes the deltas that built it.
class AssistantTextEvent extends ClaudeEvent {
  const AssistantTextEvent(this.text);
  final String text;
}

class ToolUseEvent extends ClaudeEvent {
  const ToolUseEvent(this.id, this.name, this.input);
  final String id;
  final String name;
  final Map<String, Object?> input;

  String get summary => toolSummary(name, input);
}

class ToolResultEvent extends ClaudeEvent {
  const ToolResultEvent(this.toolUseId, this.text, this.isError);
  final String toolUseId;
  final String text;
  final bool isError;
}

/// End of a turn.
class ResultEvent extends ClaudeEvent {
  const ResultEvent({
    required this.sessionId,
    required this.text,
    required this.isError,
    this.costUsd,
    this.durationMs,
  });
  final String sessionId;
  final String text;
  final bool isError;
  final double? costUsd;
  final int? durationMs;
}

/// The process died or could not start.
class ProcessErrorEvent extends ClaudeEvent {
  const ProcessErrorEvent(this.message);
  final String message;
}

/// One-line description of a tool call, as shown in the chat.
String toolSummary(String name, Map<String, Object?> input) {
  String? s(String k) {
    final v = input[k];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  final detail = switch (name) {
    'Bash' => s('description') ?? s('command'),
    'Read' || 'Edit' || 'Write' || 'NotebookEdit' => s('file_path'),
    'WebFetch' => s('url'),
    'WebSearch' => s('query'),
    'Grep' || 'Glob' => s('pattern'),
    'Agent' || 'Task' => s('description'),
    'Skill' => s('skill'),
    _ => null,
  };
  final one = detail?.split('\n').first;
  return one == null ? name : '$name: ${one.length > 140 ? '${one.substring(0, 140)}...' : one}';
}

/// Parses one stream-json line into zero or more events.
List<ClaudeEvent> parseStreamLine(String line) {
  final Object? j;
  try {
    j = jsonDecode(line);
  } on FormatException {
    return const [];
  }
  if (j is! Map<String, Object?>) return const [];
  switch (j['type']) {
    case 'system' when j['subtype'] == 'init':
      return [InitEvent('${j['session_id']}', j['model'] as String?)];
    case 'stream_event':
      final e = j['event'];
      if (e is Map<String, Object?> && e['type'] == 'content_block_delta') {
        final d = e['delta'];
        if (d is Map<String, Object?> && d['type'] == 'text_delta') {
          return [TextDeltaEvent('${d['text'] ?? ''}')];
        }
      }
      return const [];
    case 'assistant':
      return [
        for (final b in _blocks(j))
          if (b['type'] == 'text')
            AssistantTextEvent('${b['text'] ?? ''}')
          else if (b['type'] == 'tool_use')
            ToolUseEvent(
              '${b['id'] ?? ''}',
              '${b['name'] ?? ''}',
              b['input'] is Map<String, Object?> ? b['input'] as Map<String, Object?> : const {},
            ),
      ];
    case 'user':
      return [
        for (final b in _blocks(j))
          if (b['type'] == 'tool_result')
            ToolResultEvent('${b['tool_use_id'] ?? ''}', contentText(b['content']),
                b['is_error'] == true),
      ];
    case 'result':
      return [
        ResultEvent(
          sessionId: '${j['session_id'] ?? ''}',
          text: '${j['result'] ?? ''}',
          isError: j['is_error'] == true || j['subtype'] != 'success',
          costUsd: (j['total_cost_usd'] as num?)?.toDouble(),
          durationMs: (j['duration_ms'] as num?)?.toInt(),
        ),
      ];
  }
  return const [];
}

List<Map<String, Object?>> _blocks(Map<String, Object?> j) {
  final m = j['message'];
  if (m is! Map<String, Object?>) return const [];
  final c = m['content'];
  return c is List ? c.whereType<Map<String, Object?>>().toList() : const [];
}

/// Flattens tool_result / message content (string or block list) to text.
String contentText(Object? c) {
  if (c is String) return c;
  if (c is List) {
    return c
        .whereType<Map<String, Object?>>()
        .where((b) => b['type'] == 'text')
        .map((b) => '${b['text'] ?? ''}')
        .join('\n');
  }
  return '';
}

List<String> _baseArgs(String? model) => [
      // The personal-information folder lives outside the agenda; let every session read and update it.
      if (Directory(AgendaPaths.personalDir).existsSync()) ...['--add-dir', AgendaPaths.personalDir],
      '--output-format', 'stream-json', '--verbose', //
      '--dangerously-skip-permissions',
      if (model != null) ...['--model', model],
    ];

/// A multi-turn chat that reports what happens as [ClaudeEvent]s: Claude Code on
/// the desktop ([ClaudeChat]), the Messages API on the phone.
abstract interface class ChatEngine {
  Stream<ClaudeEvent> get events;
  String? get sessionId;
  abstract String? appendSystemPrompt;
  bool get busy;
  Future<void> send(String text);
  Future<void> stop();
  Future<void> dispose();
}

/// A live, multi-turn chat: one `claude` process fed user turns as stream-json
/// on stdin. Stopping kills the process; the next [send] resumes the session.
class ClaudeChat implements ChatEngine {
  ClaudeChat({required this.cwd, this.sessionId, this.model, this.appendSystemPrompt});

  final String cwd;
  final String? model;

  /// Extra system prompt for every process start (e.g. the task a thread is about).
  @override
  String? appendSystemPrompt;
  @override
  String? sessionId;

  final _events = StreamController<ClaudeEvent>.broadcast();
  Stream<ClaudeEvent> get events => _events.stream;

  Process? _process;
  bool _busy = false;
  bool _stopping = false;
  final _stderrTail = <String>[];

  /// True while a turn is in flight.
  bool get busy => _busy;

  Future<void> _start() async {
    final args = [
      '-p', '--input-format', 'stream-json', '--include-partial-messages', //
      ..._baseArgs(model),
      if (sessionId != null) ...['--resume', sessionId!],
      if (appendSystemPrompt != null) ...['--append-system-prompt', appendSystemPrompt!],
    ];
    final p = await Process.start(AgendaPaths.claudeBinary, args, workingDirectory: cwd);
    _process = p;
    _stopping = false;
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      for (final e in parseStreamLine(line)) {
        if (e is InitEvent) sessionId = e.sessionId;
        if (e is ResultEvent) {
          if (e.sessionId.isNotEmpty) sessionId = e.sessionId;
          _busy = false;
        }
        _events.add(e);
      }
    });
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _stderrTail.add(line);
      if (_stderrTail.length > 20) _stderrTail.removeAt(0);
    });
    unawaited(p.exitCode.then((code) {
      if (!identical(_process, p)) return;
      _process = null;
      final wasBusy = _busy;
      _busy = false;
      if (!_stopping && (wasBusy || code != 0)) {
        _events.add(ProcessErrorEvent(
            'claude exited with code $code${_stderrTail.isEmpty ? '' : ': ${_stderrTail.join('\n')}'}'));
      }
    }));
  }

  /// Sends one user turn, starting (or resuming) the process if needed.
  Future<void> send(String text) async {
    if (_process == null) {
      try {
        await _start();
      } on ProcessException catch (e) {
        _events.add(ProcessErrorEvent('cannot start claude: ${e.message}'));
        return;
      }
    }
    _busy = true;
    _process!.stdin.writeln(jsonEncode({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    }));
    await _process!.stdin.flush();
  }

  /// Interrupts the current turn by ending the process (SIGINT, then SIGKILL).
  Future<void> stop() async {
    final p = _process;
    if (p == null) return;
    _stopping = true;
    p.kill(ProcessSignal.sigint);
    final exited = await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    if (exited == -1) p.kill(ProcessSignal.sigkill);
    if (identical(_process, p)) _process = null;
    _busy = false;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

/// Outcome of a one-shot background run.
class RunOutcome {
  RunOutcome({this.sessionId, this.result, required this.exitCode, this.timedOut = false});
  final String? sessionId;
  final ResultEvent? result;
  final int exitCode;
  final bool timedOut;
}

/// Runs one prompt to completion (`claude -p PROMPT`), streaming events to [onEvent].
Future<RunOutcome> runClaudeOnce({
  required String cwd,
  required String prompt,
  String? model,
  Duration timeout = const Duration(minutes: 20),
  void Function(ClaudeEvent)? onEvent,
}) async {
  final p = await Process.start(
    AgendaPaths.claudeBinary,
    ['-p', prompt, ..._baseArgs(model)],
    workingDirectory: cwd,
  );
  await p.stdin.close();
  String? sid;
  ResultEvent? result;
  final done = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
    for (final e in parseStreamLine(line)) {
      if (e is InitEvent) sid = e.sessionId;
      if (e is ResultEvent) result = e;
      onEvent?.call(e);
    }
  });
  final stderrDone = p.stderr.drain<void>();
  var timedOut = false;
  final code = await p.exitCode.timeout(timeout, onTimeout: () {
    timedOut = true;
    p.kill(ProcessSignal.sigterm);
    return -1;
  });
  if (timedOut) {
    await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -9;
    });
  }
  await done.timeout(const Duration(seconds: 5), onTimeout: () {});
  await stderrDone.timeout(const Duration(seconds: 1), onTimeout: () {});
  return RunOutcome(
    sessionId: result?.sessionId ?? sid,
    result: result,
    exitCode: code,
    timedOut: timedOut,
  );
}
