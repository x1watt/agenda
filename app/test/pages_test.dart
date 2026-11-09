import 'dart:convert';
import 'dart:io';

import 'package:agenda/src/app_controller.dart';
import 'package:agenda/src/thread_context.dart';
import 'package:agenda/src/ui/theme.dart';
import 'package:agenda/src/ui/home.dart';
import 'package:agenda/src/ui/task_list_view.dart';
import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

AppController _app(String dir, Agenda agenda) {
  final app = AppController(AgendaSettings(agendaDir: dir))..personalDir = '$dir/no-personal-folder';
  app.agenda = agenda;
  app.runs = [
    RunRecord(
      id: '20260911-155229',
      reasons: ['manual run'],
      started: DateTime(2026, 9, 11, 15, 52),
      ended: DateTime(2026, 9, 11, 15, 55),
      exitCode: 0,
      sessionId: 'abc',
      summary: 'SUMMARY: all good.\nNEEDS YOU:\n- nothing',
      costUsd: 0.5,
    ),
  ];
  return app;
}

void main() {
  late Directory tmp;
  late String dir;
  late Agenda agenda;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agenda_test');
    dir = await writeFixtureAgenda(tmp);
    agenda = await loadAgenda(dir);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const nodes = ['general', 'runs', 'settings', 'personal', 'recurring', 'project:car', 'new:car', 'task:AB2-CD3', 'task:NPR-5TG', 'task:ZZZ-999'];
  for (final size in const [Size(1280, 820), Size(760, 560)]) {
    for (final node in nodes) {
      for (final mode in const ['week', 'month', 'list']) {
        testWidgets('$node renders at ${size.width.toInt()}px, $mode', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final app = _app(dir, agenda)
            ..calendarAnchor = DateTime(2026, 9, 16)
            ..monthView = mode == 'month'
            ..listMode = mode == 'list'
            ..select(node);
          await tester.pumpWidget(MaterialApp(theme: Ui.theme(), home: Home(app: app)));
          await tester.pump();
          // Lets the file rescan that a loaded chat history schedules run out.
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('week shows events, planned tasks and due dates on their days', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _app(dir, agenda)..calendarAnchor = DateTime(2026, 9, 16);
    await tester.pumpWidget(MaterialApp(theme: Ui.theme(), home: Home(app: app)));
    await tester.pump();
    expect(find.text('14:30 Insurance'), findsOneWidget);
    expect(find.text('09:00 Dentist'), findsOneWidget);
    expect(find.text('Due: Insurance'), findsOneWidget);
    // Needs-you tasks are listed under the calendar.
    expect(find.text('Needs you'), findsOneWidget);
    expect(find.textContaining('KW 38'), findsOneWidget);
  });

  testWidgets('personal info page lists and renders the files', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final personal = Directory('${tmp.path}/personal')..createSync();
    File('${personal.path}/README.md').writeAsStringSync('# Personal\n\nSee [me](me.md).');
    File('${personal.path}/me.md').writeAsStringSync('# Me\n\nBorn 29.10.1981');
    File('${personal.path}/open-questions.md').writeAsStringSync('1. one\n2. two\n');
    final app = _app(dir, agenda)
      ..personalDir = personal.path
      ..select('personal');
    // The page reads files with real I/O, so build it outside the fake clock.
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(theme: Ui.theme(), home: Home(app: app)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
    }

    await settle();
    expect(tester.takeException(), isNull);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Open questions'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.text('Me'));
    await settle();
    expect(find.textContaining('29.10.1981'), findsOneWidget);
  });

  test('ISO calendar weeks', () {
    expect(isoWeek(DateTime(2026, 9, 24)), 39);
    expect(isoWeek(DateTime(2026, 9, 21)), 39);
    expect(isoWeek(DateTime(2026, 9, 27)), 39);
    expect(isoWeek(DateTime(2026, 1, 1)), 1);
    expect(isoWeek(DateTime(2027, 1, 1)), 53);
    expect(isoWeek(DateTime(2024, 12, 30)), 1);
  });

  test('list groups: needs you first, then overdue', () {
    final open = agenda.allTasks.where((e) => e.$2.isOpen);
    final groups = {for (final (name, _, tasks) in groupTasks(open, now: DateTime(2026, 9, 20))) name: tasks.map((e) => e.$2.uid).toList()};
    expect(groups['Needs you'], ['NPR-5TG']);
    expect(groups['Overdue'], ['AB2-CD3']);
  });

  test('calendar actions write task.json and events.json', () async {
    final app = _app(dir, agenda);
    final t = app.agenda!.taskByUid('AB2-CD3')!.$2;
    await app.scheduleTask(t, '2026-09-21');
    expect(app.agenda!.taskByUid('AB2-CD3')!.$2.scheduled, '2026-09-21');
    await app.saveEvent(AgendaEvent(id: '', date: '2026-09-22', title: 'Post office'));
    expect(app.agenda!.events.map((e) => e.title), ['Dentist', 'Post office']);
    await app.deleteEvent(app.agenda!.events.first);
    expect(app.agenda!.events.single.title, 'Post office');
    app.setProjectFilter('car');
    expect(app.visibleTasks.every((e) => e.$1.id == 'car'), isTrue);
    expect(app.visibleEvents.map((e) => e.title), isEmpty);
  });

  test('recurring: add topic and item, write recurring.json, mark done advances next_due', () async {
    final app = _app(dir, agenda);
    await app.addRecurringTopic('Campervan');
    final topic = app.visibleRecurringTopics.single;
    expect(topic.id, 'campervan');
    await app.saveRecurringItem(
      topic.id,
      RecurringItem(id: '', text: 'Yearly insurance', interval: RecurringInterval.yearly, anchor: '2026-03-15', nextDue: '2026-03-15'),
    );
    final onDisk = jsonDecode(await File('$dir/recurring.json').readAsString()) as Map<String, Object?>;
    final topics = onDisk['topics'] as List;
    expect(topics, hasLength(1));
    final items = (topics.single as Map)['items'] as List;
    expect((items.single as Map)['text'], 'Yearly insurance');

    final item = app.visibleRecurringTopics.single.items.single;
    await app.markRecurringItemDone(topic.id, item.id);
    final updated = app.visibleRecurringTopics.single.items.single;
    expect(updated.nextDue, '2027-03-15');
    expect(updated.history.single.text, contains('2027-03-15'));
  });

  group('threads', () {
    const node = 'task:NPR-5TG';
    Future<Map<String, Object?>> taskJson(AppController app) async =>
        jsonDecode(await File(app.agenda!.taskByUid('NPR-5TG')!.$2.jsonPath).readAsString()) as Map<String, Object?>;

    SessionInfo local(String id) => SessionInfo(id: id, path: '$dir/$id.jsonl', title: id, lastActivity: DateTime(2026, 9, 14), sizeBytes: 1);

    test('one chat per node: a started session joins the node and the chat stays', () async {
      final app = _app(dir, agenda);
      final chat = app.chatFor(node);
      expect(chat.sessionId, isNull);
      expect(chat.readOnly, isFalse);

      chat.sessionId = 's2';
      await chat.onSessionStarted!(chat);
      expect(app.threadsFor(node).map((t) => t.id), ['live-session', 's2']);
      expect(app.chatFor(node), same(chat));

      final j = await taskJson(app);
      expect((j['threads'] as List).map((t) => (t as Map)['id']), ['live-session', 's2']);
    });

    test('messages are appended to the conversation with the session id', () async {
      final app = _app(dir, agenda);
      final chat = app.chatFor(node);
      await chat.onMessage!(chat, ConversationEntry(at: DateTime(2026, 9, 14, 10), role: 'user', text: 'hello', session: 'live-session'));
      await chat.onMessage!(chat, ConversationEntry(at: DateTime(2026, 9, 14, 10, 1), role: 'assistant', text: 'hi', session: 'live-session'));
      final j = await taskJson(app);
      final conv = (j['conversation'] as List).cast<Map<String, Object?>>();
      expect(conv.map((c) => '${c['role']}:${c['text']}'), ['user:hello', 'assistant:hi']);
      expect(conv.every((c) => c['session'] == 'live-session'), isTrue);

      // General messages land in general.json.
      final g = app.chatFor('general');
      await g.onMessage!(g, ConversationEntry(at: DateTime(2026, 9, 14), role: 'user', text: 'general hello', session: null));
      final gj = jsonDecode(await File('$dir/general.json').readAsString()) as Map<String, Object?>;
      expect((gj['conversation'] as List).single, containsPair('text', 'general hello'));
    });

    test('every stored message shows, archived threads included, and the newest local session continues', () async {
      final app = _app(dir, agenda);
      const n = 'task:AB2-CD3';
      final fresh = app.chatFor(n);
      await fresh.loadHistory();
      expect(fresh.sessionId, isNull);
      expect(fresh.readOnly, isFalse);
      expect(fresh.items.map((i) => i.text), ['Is the policy cancelled?', 'Not yet, the form needs a signature.']);

      // Once the session list shows the transcript, the chat resumes that session.
      app.sessions = [local('old-session')];
      final resumed = app.chatFor(n);
      await resumed.loadHistory();
      expect(resumed.sessionId, 'old-session');
      expect(resumed.readOnly, isFalse);
      expect(resumed.items.map((i) => i.text), ['Is the policy cancelled?', 'Not yet, the form needs a signature.']);
    });

    test('a terminal session opens read-only in General and Back returns to the General chat', () async {
      final app = _app(dir, agenda);
      app.openSession('terminal-1');
      expect(app.chatFor('general').sessionId, 'terminal-1');
      expect(app.chatFor('general').readOnly, isTrue);
      app.closeSession();
      expect(app.chatFor('general').readOnly, isFalse);
      expect(app.chatFor('general').sessionId, isNull);
    });

    test('marker helper hides an old marker', () {
      expect(stripMarker('Done.\n[[new-thread: split into two]]'), 'Done.');
    });

    test('task prompt carries the task state, items and earlier conversation', () async {
      final app = _app(dir, agenda);
      final p = threadSystemPrompt('task:AB2-CD3', app.agenda, currentSession: 'new-one');
      expect(p, contains('Insurance'));
      expect(p, contains('AB2-CD3'));
      expect(p, contains('projects/car/AB2-CD3-insurance'));
      expect(p, contains('[ ] 1: Request the mileage'));
      expect(p, contains('[x] 2: Download forms'));
      expect(p, contains('guide.md [needs_review]'));
      expect(p, contains('the form needs a signature'));
      expect(p, contains('formerly T1'));
      expect(p, contains('[[new-thread:'));
      final pp = threadSystemPrompt('project:car', app.agenda);
      expect(pp, contains('AB2-CD3 "Insurance" [todo]'));
      expect(pp, contains('2026-12-31: Change insurer'));
    });

    test('create, follow-up and edit go through the controller', () async {
      final app = _app(dir, agenda);
      final p = app.agenda!.projectById('car')!;
      final created = await app.createTask(p, name: 'Call the Finanzamt', due: '2026-10-01', priority: 2, nextStep: 'Find the number');
      expect(app.selected, 'task:${created.uid}');
      final t = app.agenda!.taskByUid('AB2-CD3')!.$2;
      final f = await app.spawnFollowUp(p, t, name: 'Post the application', moveOpenItems: true, closeOrigin: true);
      final again = app.agenda!.taskByUid('AB2-CD3')!.$2;
      expect(again.status, TaskStatus.done);
      expect(again.items.map((i) => i.done), [true]);
      expect(app.agenda!.taskByUid(f.uid)!.$2.follows, 'AB2-CD3');
      expect(app.agenda!.successorsOf('AB2-CD3').single.uid, f.uid);
      await app.editTask(f, {'name': 'Post it', 'due': null});
      expect(app.agenda!.taskByUid(f.uid)!.$2.name, 'Post it');
      await app.removeTaskItem(f, app.agenda!.taskByUid(f.uid)!.$2.items.single);
      expect(app.agenda!.taskByUid(f.uid)!.$2.items, isEmpty);
      await app.createProject('bike', 'Bike');
      expect(app.selected, 'project:bike');
      expect(app.agenda!.projectById('bike'), isNotNull);
    });

    test('task actions write task.json', () async {
      final app = _app(dir, agenda);
      final t = app.agenda!.taskByUid('AB2-CD3')!.$2;
      await app.setTaskStatus(t, TaskStatus.inProgress);
      await app.toggleItem(t, t.items.first);
      await app.addTaskItem(t, 'Post it');
      final again = app.agenda!.taskByUid('AB2-CD3')!.$2;
      expect(again.status, TaskStatus.inProgress);
      expect(again.items.first.done, isTrue);
      expect(again.items.last.text, 'Post it');
      expect(again.history.length, greaterThan(t.history.length));
    });
  });
}
