import 'dart:convert';
import 'dart:io';

import 'package:agenda/src/agent/api_chat.dart';
import 'package:agenda/src/agent/file_tools.dart';
import 'package:agenda_core/agenda_core.dart';
import 'package:flutter_test/flutter_test.dart';

String _sse(List<Map<String, Object?>> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

List<Map<String, Object?>> _toolTurn(String id, String name, Map<String, Object?> input) => [
  {'type': 'message_start', 'message': {'usage': {'input_tokens': 1000, 'output_tokens': 0}}},
  {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': ''}},
  {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'sig'}},
  {'type': 'content_block_stop', 'index': 0},
  {'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'text', 'text': ''}},
  {'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': 'Adding it.'}},
  {'type': 'content_block_stop', 'index': 1},
  {'type': 'content_block_start', 'index': 2, 'content_block': {'type': 'tool_use', 'id': id, 'name': name, 'input': {}}},
  {'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input).substring(0, 10)}},
  {'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input).substring(10)}},
  {'type': 'content_block_stop', 'index': 2},
  {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use'}, 'usage': {'output_tokens': 200}},
  {'type': 'message_stop'},
];

List<Map<String, Object?>> _textTurn(String text) => [
  {'type': 'message_start', 'message': {'usage': {'input_tokens': 10}}},
  {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}},
  {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}},
  {'type': 'content_block_stop', 'index': 0},
  {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 5}},
  {'type': 'message_stop'},
];

void main() {
  late Directory tmp;
  late HttpServer fake;
  late List<Map<String, Object?>> requests;
  late List<List<Map<String, Object?>>> script;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('api_chat');
    Directory('${tmp.path}/agenda/projects/t/AB2-CD3-x').createSync(recursive: true);
    File('${tmp.path}/agenda/projects/t/AB2-CD3-x/task.json').writeAsStringSync('{"items": []}');
    Directory('${tmp.path}/personal').createSync();
    File('${tmp.path}/secret.txt').writeAsStringSync('no');
    requests = [];
    script = [];
    fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fake.listen((req) async {
      requests.add(jsonDecode(await utf8.decodeStream(req)) as Map<String, Object?>);
      expect(req.headers.value('x-api-key'), 'sk-test');
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write(_sse(script.removeAt(0)));
      await req.response.close();
    });
  });

  tearDown(() async {
    await fake.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  ApiChat chat({String? session}) => ApiChat(
    tools: FileTools(agendaDir: '${tmp.path}/agenda', personalDir: '${tmp.path}/personal'),
    transcriptDir: '${tmp.path}/transcripts',
    apiKey: () async => 'sk-test',
    baseSystem: () async => 'RULES',
    sessionId: session,
    endpoint: 'http://127.0.0.1:${fake.port}/v1/messages',
  );

  test('tool loop edits a file, replays thinking, resumes from the transcript', () async {
    script = [
      _toolTurn('t1', 'Edit', {'file_path': 'projects/t/AB2-CD3-x/task.json', 'old_string': '"items": []', 'new_string': '"items": [{"id": "1"}]'}),
      _textTurn('Done.'),
    ];
    final c = chat()..appendSystemPrompt = 'Task AB2-CD3';
    final events = <ClaudeEvent>[];
    final sub = c.events.listen(events.add);
    await c.send('Add an item');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    for (final e in events.whereType<ProcessErrorEvent>()) {
      fail(e.message);
    }
    expect(File('${tmp.path}/agenda/projects/t/AB2-CD3-x/task.json').readAsStringSync(), '{"items": [{"id": "1"}]}');
    expect(events.whereType<InitEvent>(), hasLength(1));
    expect(events.whereType<ToolUseEvent>().single.name, 'Edit');
    expect(events.whereType<ToolResultEvent>().single.isError, isFalse);
    final result = events.whereType<ResultEvent>().single;
    expect(result.text, 'Done.');
    expect(result.costUsd, greaterThan(0));
    // Second request replays the thinking block unchanged and sends the tool result.
    final second = requests[1]['messages']! as List;
    expect(((second[1] as Map)['content'] as List).first, {'type': 'thinking', 'thinking': '', 'signature': 'sig'});
    expect(((second[2] as Map)['content'] as List).first['type'], 'tool_result');
    expect(requests[0]['model'], 'claude-opus-5');
    expect(requests[0]['fallbacks'], 'default');
    // The task state rides in the first user turn, not the system prompt.
    expect((requests[0]['system']! as List).first['text'], 'RULES');
    expect(jsonEncode(requests[0]['messages']), contains('Task AB2-CD3'));

    // Resume: a new engine for the same session rebuilds the history.
    script = [_textTurn('Hi again.')];
    final again = chat(session: c.sessionId)..appendSystemPrompt = 'Task AB2-CD3';
    await again.send('And now?');
    expect((requests.last['messages']! as List).length, 5);
    // The history reader of the desktop understands the transcript.
    final items = readTranscriptSync('${tmp.path}/transcripts/${c.sessionId}.jsonl');
    expect(items.map((i) => i.text), containsAll(['Add an item', 'Adding it.', 'Done.', 'And now?', 'Hi again.']));
  });

  test('file tools stay inside the two folders', () async {
    final t = FileTools(agendaDir: '${tmp.path}/agenda', personalDir: '${tmp.path}/personal');
    expect(t.resolve('../secret.txt'), isNull);
    expect(t.resolve('${tmp.path}/secret.txt'), isNull);
    expect(t.resolve('~/personal/me.md'), '${tmp.path}/personal/me.md');
    final (out, err) = await t.run('Read', {'file_path': '../secret.txt'});
    expect(err, isTrue);
    expect('$out', contains('outside'));
    final (w, werr) = await t.run('Write', {'file_path': 'projects/t/bad.json', 'content': '{nope'});
    expect(werr, isTrue, reason: '$w');
    final (g, _) = await t.run('Glob', {'pattern': 'projects/**/task.json'});
    expect(g, 'projects/t/AB2-CD3-x/task.json');
  });
}
