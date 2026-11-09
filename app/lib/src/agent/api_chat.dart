import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agenda_core/agenda_core.dart';

import 'file_tools.dart';

/// Claude on the phone: the Messages API with the file tools, reported as the same
/// [ClaudeEvent]s as Claude Code on the desktop, so the chat UI is shared.
///
/// The transcript is written as JSONL in the shape of a Claude Code session file
/// (`{"type": "user"|"assistant", "message": {...}}`), so the existing history
/// reader shows it, and the API messages are rebuilt from it to resume a thread.
/// The history is append-only: the system prompt is frozen when the thread starts
/// and later task state goes into the user turn, which keeps prompt caching and
/// thinking-block replay valid.
class ApiChat implements ChatEngine {
  ApiChat({
    required this.tools,
    required this.transcriptDir,
    required this.apiKey,
    required this.baseSystem,
    this.sessionId,
    this.model = defaultModel,
    this.endpoint = 'https://api.anthropic.com/v1/messages',
  });

  static const defaultModel = 'claude-opus-5';

  /// USD per million tokens for claude-opus-5: input, output, cache write, cache read.
  static const _price = (5.0, 25.0, 6.25, 0.5);

  final FileTools tools;
  final String transcriptDir;
  final Future<String?> Function() apiKey;

  /// The agenda rules (CLAUDE.md and friends), read when a thread starts.
  final Future<String> Function() baseSystem;
  final String model;

  /// The Messages API URL (tests point it at a local fake).
  final String endpoint;

  @override
  String? sessionId;

  /// The current state of the task this thread is about (set before each send).
  @override
  String? appendSystemPrompt;

  final _events = StreamController<ClaudeEvent>.broadcast();
  @override
  Stream<ClaudeEvent> get events => _events.stream;

  bool _busy = false;
  @override
  bool get busy => _busy;

  String? _system;
  String? _lastState;
  List<Map<String, Object?>>? _messages;
  HttpClient? _http;
  bool _stopped = false;

  File get _transcript => File('$transcriptDir/$sessionId.jsonl');

  static String _uuid() {
    final r = Random.secure();
    final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> _append(Map<String, Object?> line) async {
    await _transcript.parent.create(recursive: true);
    await _transcript.writeAsString('${jsonEncode({...line, 'timestamp': DateTime.now().toUtc().toIso8601String()})}\n', mode: FileMode.append, flush: true);
  }

  /// Rebuilds the API messages of an existing thread from its transcript.
  Future<void> _load() async {
    final msgs = <Map<String, Object?>>[];
    if (await _transcript.exists()) {
      for (final line in await _transcript.readAsLines()) {
        if (!line.startsWith('{')) continue;
        try {
          final j = jsonDecode(line) as Map<String, Object?>;
          switch (j['type']) {
            case 'system':
              _system = '${j['text']}';
              _lastState = j['state'] as String?;
            case 'state':
              _lastState = j['state'] as String?;
            case 'user' || 'assistant':
              msgs.add((j['message']! as Map).cast<String, Object?>());
          }
        } on Object {
          continue;
        }
      }
    }
    // A turn interrupted between a tool call and its result: close it off.
    if (msgs.isNotEmpty && msgs.last['role'] == 'assistant') {
      final pending = _toolUses(msgs.last['content']);
      if (pending.isNotEmpty) {
        final m = {
          'role': 'user',
          'content': [
            for (final t in pending) {'type': 'tool_result', 'tool_use_id': t['id'], 'content': 'Interrupted before the tool ran.', 'is_error': true},
          ],
        };
        msgs.add(m);
        await _append({'type': 'user', 'message': m});
      }
    }
    _messages = msgs;
  }

  static List<Map<String, Object?>> _toolUses(Object? content) =>
      content is List ? content.whereType<Map<String, Object?>>().where((b) => b['type'] == 'tool_use').toList() : const [];

  @override
  Future<void> send(String text) async {
    if (_busy) return;
    _busy = true;
    _stopped = false;
    try {
      final key = await apiKey();
      if (key == null || key.isEmpty) {
        _events.add(const ProcessErrorEvent('No Anthropic API key on this phone. Pair with the desktop again or paste one in Settings.'));
        _busy = false;
        return;
      }
      if (sessionId == null) {
        sessionId = _uuid();
        _system = await baseSystem();
        _lastState = appendSystemPrompt;
        _messages = [];
        await _append({'type': 'system', 'text': _system, 'state': _lastState});
      } else if (_messages == null) {
        await _load();
        _system ??= await baseSystem();
      }
      _events.add(InitEvent(sessionId!, model));

      final content = <Map<String, Object?>>[];
      final state = appendSystemPrompt;
      if (_messages!.isEmpty && state != null) {
        content.add({'type': 'text', 'text': '<system-reminder>\n$state\n</system-reminder>'});
      } else if (state != null && state != _lastState) {
        content.add({'type': 'text', 'text': '<system-reminder>\nThe state of this topic now (it changed since the last message):\n$state\n</system-reminder>'});
        await _append({'type': 'state', 'state': state});
      }
      _lastState = state;
      content.add({'type': 'text', 'text': text});
      final msgs = _messages!;
      if (msgs.isNotEmpty && msgs.last['role'] == 'user') {
        // The previous user turn never got an answer: continue it instead of starting a second one.
        final last = msgs.last;
        last['content'] = [...(last['content']! as List), ...content];
      } else {
        msgs.add({'role': 'user', 'content': content});
      }
      await _append({'type': 'user', 'message': {'role': 'user', 'content': content}});
      await _loop(key);
    } on Object catch (e) {
      _events.add(ProcessErrorEvent(_stopped ? 'Stopped.' : 'Claude API: $e'));
    } finally {
      _busy = false;
      _http?.close(force: true);
      _http = null;
    }
  }

  Future<void> _loop(String key) async {
    var cost = 0.0;
    var lastText = '';
    for (var round = 0; round < 80; round++) {
      if (_stopped) return;
      final (blocks, stopReason, usage) = await _request(key);
      cost += _cost(usage);
      final replay = _forReplay(blocks, refused: stopReason == 'refusal');
      final assistant = {'role': 'assistant', 'content': replay};
      _messages!.add(assistant);
      await _append({'type': 'assistant', 'message': assistant});
      final texts = blocks.where((b) => b['type'] == 'text').map((b) => '${b['text']}').where((t) => t.trim().isNotEmpty);
      if (texts.isNotEmpty) lastText = texts.last;

      switch (stopReason) {
        case 'tool_use':
          final results = <Map<String, Object?>>[];
          for (final b in _toolUses(replay)) {
            final id = '${b['id']}';
            final (Object out, bool isError) = b['_invalid'] == true
                ? ('INVALID_JSON: the tool input was cut off or malformed. Send the call again.', true)
                : await tools.run('${b['name']}', (b['input'] as Map?)?.cast<String, Object?>() ?? const {});
            results.add({'type': 'tool_result', 'tool_use_id': id, 'content': out, if (isError) 'is_error': true});
            _events.add(ToolResultEvent(id, out is String ? out : '(${(out as List).length} block)', isError));
            if (_stopped) break;
          }
          final m = {'role': 'user', 'content': results};
          _messages!.add(m);
          await _append({'type': 'user', 'message': m});
          continue;
        case 'pause_turn':
          continue; // a server tool paused a long turn; send it back to continue
        case 'refusal':
          _events.add(const ProcessErrorEvent('Claude declined this request.'));
          return;
        case 'max_tokens':
          _events.add(ResultEvent(sessionId: sessionId!, text: lastText, isError: true, costUsd: cost));
          _events.add(const ProcessErrorEvent('The answer hit the length limit. Ask Claude to continue.'));
          return;
        default:
          _events.add(ResultEvent(sessionId: sessionId!, text: lastText, isError: false, costUsd: cost));
          return;
      }
    }
    _events.add(ResultEvent(sessionId: sessionId!, text: lastText, isError: true, costUsd: cost));
  }

  double _cost(Map<String, Object?> u) {
    num n(String k) => (u[k] as num?) ?? 0;
    return (n('input_tokens') * _price.$1 +
            n('output_tokens') * _price.$2 +
            n('cache_creation_input_tokens') * _price.$3 +
            n('cache_read_input_tokens') * _price.$4) /
        1e6;
  }

  /// The assistant content as it must go back to the API. After a mid-output
  /// fallback, blocks of the declined attempt before the last `fallback` marker
  /// (thinking, tool calls, unpaired server tool calls) are left out; a refusal
  /// keeps only its text.
  static List<Map<String, Object?>> _forReplay(List<Map<String, Object?>> blocks, {required bool refused}) {
    var out = [for (final b in blocks) Map<String, Object?>.of(b)];
    final fb = out.lastIndexWhere((b) => b['type'] == 'fallback');
    if (fb >= 0) {
      final resultIds = {for (final b in out) if (b['tool_use_id'] != null && '${b['type']}'.endsWith('_tool_result')) b['tool_use_id']};
      out = [
        for (var i = 0; i < out.length; i++)
          if (i >= fb ||
              out[i]['type'] == 'text' ||
              ('${out[i]['type']}'.endsWith('_tool_result')) ||
              (out[i]['type'] == 'server_tool_use' && resultIds.contains(out[i]['id'])))
            out[i],
      ];
    }
    if (refused) out = out.where((b) => b['type'] == 'text').toList();
    if (out.isEmpty) out = [{'type': 'text', 'text': refused ? '(declined)' : '(no answer)'}];
    return out;
  }

  Map<String, Object?> _body() => {
    'model': model,
    'max_tokens': 64000,
    'stream': true,
    'thinking': {'type': 'adaptive'},
    'cache_control': {'type': 'ephemeral'},
    'fallbacks': 'default',
    'system': [
      {'type': 'text', 'text': _system},
    ],
    'tools': [
      ...FileTools.definitions,
      {'type': 'web_search_20260209', 'name': 'web_search'},
      {'type': 'web_fetch_20260209', 'name': 'web_fetch'},
    ],
    'messages': [
      for (final m in _messages!)
        {
          'role': m['role'],
          'content': m['content'] is List
              ? [for (final b in (m['content']! as List).cast<Map<String, Object?>>()) Map.fromEntries(b.entries.where((e) => !e.key.startsWith('_')))]
              : m['content'],
        },
    ],
  };

  /// One streamed request. Returns the content blocks, the stop reason and the usage.
  Future<(List<Map<String, Object?>>, String?, Map<String, Object?>)> _request(String key) async {
    for (var attempt = 0;; attempt++) {
      final http = _http = HttpClient();
      final req = await http.postUrl(Uri.parse(endpoint));
      req.headers
        ..set('x-api-key', key)
        ..set('anthropic-version', '2023-06-01')
        ..set('anthropic-beta', 'server-side-fallback-2026-07-01')
        ..contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(_body())));
      final res = await req.close();
      if (res.statusCode == 429 || res.statusCode == 529 || res.statusCode >= 500) {
        await res.drain<void>();
        if (attempt >= 3) throw HttpException('the API is busy (${res.statusCode}); try again later');
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
        continue;
      }
      if (res.statusCode != 200) {
        final body = await utf8.decodeStream(res);
        String msg = body;
        try {
          msg = '${((jsonDecode(body) as Map)['error'] as Map)['message']}';
        } on Object {
          // keep the raw body
        }
        throw HttpException('${res.statusCode}: $msg');
      }
      return _readStream(res);
    }
  }

  Future<(List<Map<String, Object?>>, String?, Map<String, Object?>)> _readStream(HttpClientResponse res) async {
    final blocks = <int, Map<String, Object?>>{};
    final partial = <int, StringBuffer>{};
    final usage = <String, Object?>{};
    String? stop;
    var data = StringBuffer();

    void handle(Map<String, Object?> e) {
      switch (e['type']) {
        case 'message_start':
          final u = ((e['message'] as Map?)?['usage'] as Map?)?.cast<String, Object?>();
          if (u != null) usage.addAll(u);
        case 'content_block_start':
          final i = (e['index']! as num).toInt();
          final b = Map<String, Object?>.of((e['content_block']! as Map).cast<String, Object?>());
          blocks[i] = b;
          if (b['type'] == 'tool_use' || b['type'] == 'server_tool_use') partial[i] = StringBuffer();
          if ('${b['type']}'.endsWith('_tool_result') && b['tool_use_id'] != null) {
            final failed = b['content'] is Map && (b['content']! as Map).containsKey('error_code');
            _events.add(ToolResultEvent('${b['tool_use_id']}', failed ? 'failed' : 'done', failed));
          }
        case 'content_block_delta':
          final i = (e['index']! as num).toInt();
          final b = blocks[i];
          final d = (e['delta']! as Map).cast<String, Object?>();
          if (b == null) return;
          switch (d['type']) {
            case 'text_delta':
              b['text'] = '${b['text'] ?? ''}${d['text']}';
              _events.add(TextDeltaEvent('${d['text']}'));
            case 'input_json_delta':
              partial[i]?.write(d['partial_json'] ?? '');
            case 'thinking_delta':
              b['thinking'] = '${b['thinking'] ?? ''}${d['thinking']}';
            case 'signature_delta':
              b['signature'] = '${b['signature'] ?? ''}${d['signature']}';
            case 'citations_delta':
              b['citations'] = [...((b['citations'] as List?) ?? const []), d['citation']];
          }
        case 'content_block_stop':
          final i = (e['index']! as num).toInt();
          final b = blocks[i];
          if (b == null) return;
          final p = partial.remove(i);
          if (p != null) {
            try {
              b['input'] = p.isEmpty ? <String, Object?>{} : jsonDecode(p.toString());
              if (b['type'] == 'tool_use') {
                final problem = FileTools.validate('${b['name']}', (b['input']! as Map).cast<String, Object?>());
                if (problem != null) b['_invalid'] = true;
              }
            } on FormatException {
              b['input'] = <String, Object?>{};
              b['_invalid'] = true;
            }
            final input = (b['input']! as Map).cast<String, Object?>();
            final name = switch ('${b['name']}') {
              'web_search' => 'WebSearch',
              'web_fetch' => 'WebFetch',
              final n => n,
            };
            _events.add(ToolUseEvent('${b['id']}', name, {...input, if (input['query'] != null) 'query': input['query']}));
          }
          if (b['type'] == 'text' && '${b['text'] ?? ''}'.trim().isNotEmpty) _events.add(AssistantTextEvent('${b['text']}'));
        case 'message_delta':
          stop = ((e['delta'] as Map?)?['stop_reason']) as String? ?? stop;
          final u = (e['usage'] as Map?)?.cast<String, Object?>();
          if (u != null) usage.addAll(u);
        case 'error':
          throw HttpException('${(e['error'] as Map?)?['message'] ?? 'stream error'}');
      }
    }

    await for (final line in res.transform(utf8.decoder).transform(const LineSplitter())) {
      if (_stopped) break;
      if (line.startsWith('data:')) {
        data.write(line.substring(5).trimLeft());
      } else if (line.isEmpty && data.isNotEmpty) {
        final raw = data.toString();
        data = StringBuffer();
        final Object? j;
        try {
          j = jsonDecode(raw);
        } on FormatException {
          continue;
        }
        if (j is Map<String, Object?>) handle(j);
      }
    }
    final keys = blocks.keys.toList()..sort();
    return ([for (final k in keys) blocks[k]!], stop, usage);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _http?.close(force: true);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}
