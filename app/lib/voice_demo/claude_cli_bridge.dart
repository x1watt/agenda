import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Talks to the local `claude` CLI in print mode: the same claude.ai subscription
/// login already set up on this machine, no separate API key or billing. Always
/// run from [workingDirectory], a scratch folder outside any project, so no
/// CLAUDE.md or project context gets pulled in — this is a bare conversation.
///
/// Keeps ONE `claude` process alive for the whole conversation (streaming JSON
/// in/out) instead of spawning a fresh process per turn: a fresh process repeats
/// the full session bootstrap (SessionStart hooks, model/tool init, cold prompt
/// cache) on every single turn, which dominated turn latency far more than actual
/// model thinking time did.
class ClaudeCliBridge {
  ClaudeCliBridge({required this.workingDirectory, required this.systemPrompt});

  final String workingDirectory;
  final String systemPrompt;

  Process? _proc;
  StreamSubscription<String>? _stdoutSub;
  Completer<ClaudeTurnResult>? _pending;

  Future<void> _ensureStarted() async {
    if (_proc != null) return;
    final proc = await Process.start(
      'claude',
      [
        '-p',
        '--input-format', 'stream-json',
        '--output-format', 'stream-json',
        '--verbose',
        '--system-prompt', systemPrompt,
      ],
      workingDirectory: workingDirectory,
    );
    _proc = proc;
    _stdoutSub = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    proc.stderr.transform(utf8.decoder).listen((_) {}); // drained, not surfaced per line
    unawaited(proc.exitCode.then((_) {
      _proc = null;
      _pending?.completeError(StateError('claude process exited'));
      _pending = null;
    }));
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, Object?> j;
    try {
      j = jsonDecode(line) as Map<String, Object?>;
    } catch (_) {
      return; // not a JSON line we understand; ignore
    }
    if (j['type'] != 'result') return; // system/rate_limit_event/etc: not a turn boundary

    final pending = _pending;
    _pending = null;
    if (pending == null) return;

    if (j['is_error'] == true) {
      pending.completeError(StateError('claude error: ${j['result']}'));
      return;
    }
    pending.complete(ClaudeTurnResult(
      text: '${j['result'] ?? ''}',
      elapsed: Duration(milliseconds: (j['duration_ms'] as num?)?.toInt() ?? 0),
      costUsd: (j['total_cost_usd'] as num?)?.toDouble(),
    ));
  }

  /// Sends [text] as the next conversation turn and waits for the reply. Only
  /// one turn is ever in flight (the voice pipeline awaits each turn fully
  /// before starting the next), so a single pending completer is enough.
  Future<ClaudeTurnResult> ask(String text) async {
    await _ensureStarted();
    final proc = _proc;
    if (proc == null) throw StateError('claude process is not running');
    if (_pending != null) throw StateError('a turn is already in flight');

    final completer = Completer<ClaudeTurnResult>();
    _pending = completer;
    final line = jsonEncode({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
    });
    proc.stdin.writeln(line);
    await proc.stdin.flush();
    return completer.future;
  }

  Future<void> dispose() async {
    final proc = _proc;
    if (proc == null) return;
    await _stdoutSub?.cancel();
    try {
      await proc.stdin.close();
      await proc.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      proc.kill();
    }
    _proc = null;
  }
}

class ClaudeTurnResult {
  ClaudeTurnResult({required this.text, required this.elapsed, this.costUsd});
  final String text;
  final Duration elapsed;
  final double? costUsd;
}
