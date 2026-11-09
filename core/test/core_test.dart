import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:test/test.dart';

import 'fixture.dart';


void main() {

  group('stream-json', () {
    final events = File('test/fixtures/stream_pong.jsonl')
        .readAsLinesSync()
        .expand(parseStreamLine)
        .toList();

    test('init, deltas, final text and result', () {
      expect(events.whereType<InitEvent>().single.sessionId, isNotEmpty);
      expect(events.whereType<TextDeltaEvent>().map((e) => e.text).join(), 'pong');
      expect(events.whereType<AssistantTextEvent>().single.text, 'pong');
      final r = events.whereType<ResultEvent>().single;
      expect(r.text, 'pong');
      expect(r.isError, isFalse);
      expect(r.costUsd, greaterThan(0));
    });

    test('tool use and tool result', () {
      final use = parseStreamLine('{"type":"assistant","message":{"content":[{"type":"tool_use",'
          '"id":"t1","name":"Bash","input":{"command":"ls","description":"List files"}}]}}');
      expect((use.single as ToolUseEvent).summary, 'Bash: List files');
      final res = parseStreamLine('{"type":"user","message":{"content":[{"type":"tool_result",'
          '"tool_use_id":"t1","content":[{"type":"text","text":"a b"}],"is_error":true}]}}');
      final r = res.single as ToolResultEvent;
      expect(r.text, 'a b');
      expect(r.isError, isTrue);
    });

    test('garbage lines are ignored', () {
      expect(parseStreamLine('not json'), isEmpty);
      expect(parseStreamLine('{"type":"rate_limit_event"}'), isEmpty);
    });
  });

  group('transcripts', () {
    test('user and assistant turns in order, thinking skipped', () {
      final items = readTranscriptSync('test/fixtures/session_kiwi.jsonl');
      expect(items.map((i) => '${i.role.name}:${i.text}'), [
        'user:Remember the word: kiwi. Reply ok.',
        'assistant:ok',
        'user:Which word did I ask you to remember? One word.',
        'assistant:kiwi',
        'user:What was the word again? One word.',
        'assistant:kiwi',
      ]);
    });

    test('tool results attach to their tool line; reminders are stripped', () {
      final items = parseTranscript([
        '{"type":"user","message":{"role":"user","content":"hi<system-reminder>x</system-reminder>"}}',
        '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Read",'
            '"input":{"file_path":"/x/next.md"}}]}}',
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"body"}]}}',
        '{"type":"user","isMeta":true,"message":{"content":"meta"}}',
        '{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}',
      ]);
      expect(items, hasLength(2));
      expect(items[0].text, 'hi');
      expect(items[1].text, 'Read: /x/next.md');
      expect(items[1].detail, 'body');
    });

    test('lists sessions with titles', () async {
      final list = await listSessions('test/fixtures');
      final kiwi = list.singleWhere((s) => s.id == 'session_kiwi');
      expect(kiwi.title, isNotEmpty);
      expect(kiwi.title, isNot('(empty session)'));
    });
  });

  group('checker decisions', () {
    final morning = DateTime(2026, 9, 12, 9);
    List<String> decide({
      CheckState? state,
      String? boot = 'b1',
      bool runNow = false,
      List<MailHeader> mail = const [],
      List<Deadline> deadlines = const [],
      DateTime? now,
    }) =>
        decideReasons(
          now: now ?? morning,
          state: state ?? CheckState(bootId: 'b1', lastFullRun: DateTime(2026, 9, 12, 8)),
          bootId: boot,
          runNow: runNow,
          newMail: mail,
          deadlines: deadlines,
          dailyRunHour: 7,
        );

    test('quiet tick does nothing', () => expect(decide(), isEmpty));
    test('new boot wakes Claude', () => expect(decide(boot: 'b2'), ['first check after boot']));
    test('daily review once after the hour', () {
      expect(decide(state: CheckState(bootId: 'b1', lastFullRun: DateTime(2026, 9, 11, 23))),
          ['daily review']);
      expect(
          decide(
              state: CheckState(bootId: 'b1', lastFullRun: DateTime(2026, 9, 11, 23)),
              now: DateTime(2026, 9, 12, 6)),
          isEmpty);
    });
    test('manual run, mail and deadlines', () {
      final r = decide(
        runNow: true,
        mail: [MailHeader(uid: 5, from: 'OCU', subject: 'Termin')],
        deadlines: [Deadline(date: '2026-09-12', text: 'Roof check')],
      );
      expect(r, ['manual run', 'new mail: OCU, "Termin"', 'deadline 2026-09-12: Roof check']);
    });
    test('deadline window announces once', () async {
      final tmp = Directory.systemTemp.createTempSync('agenda_core');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final a = await loadAgenda(await writeFixtureAgenda(tmp));
      final state = CheckState();
      final first = deadlinesEnteringWindow(a, state, DateTime(2026, 9, 11, 10));
      expect(first.map((d) => d.text), ['Roof check']);
      state.notifiedDeadlines.addAll(first.map(deadlineKey));
      expect(deadlinesEnteringWindow(a, state, DateTime(2026, 9, 11, 10)), isEmpty);
    });
    test('state round-trips and caps seen', () {
      final s = CheckState(bootId: 'x', seen: {for (var i = 0; i < 2500; i++) 'INBOX:$i'});
      final again = CheckState.fromJson(s.toJson());
      expect(again.bootId, 'x');
      expect(again.seen, hasLength(2000));
      expect(again.seen.contains('INBOX:2499'), isTrue);
    });
  });

  test('mail helpers', () {
    expect(imapDate(DateTime(2026, 9, 1)), '01-Sep-2026');
    expect(imapQuote('a"b'), r'"a\"b"');
    expect(fromAnyCriteria(['a']), 'FROM "a"');
    expect(fromAnyCriteria(['a', 'b', 'c']), 'OR FROM "a" OR FROM "b" FROM "c"');
    expect(parseInternalDate('11-Sep-2026 13:50:00 +0000')!.toUtc(), DateTime.utc(2026, 9, 11, 13, 50));
  });
}

