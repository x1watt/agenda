import 'dart:convert';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory tmp;
  late String dir;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agenda_model');
    dir = await writeFixtureAgenda(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('loadAgenda', () {
    test('projects, tasks from folders, fields', () async {
      final a = await loadAgenda(dir);
      expect(a.errors, isEmpty);
      expect(a.projects.map((p) => p.id), ['car', 'house']);
      final car = a.projectById('car')!;
      expect(car.tasks.map((t) => t.uid), ['AB2-CD3', 'XY7-Q8W']);
      expect(car.docs, ['data/TASKS.md']);
      expect(car.dir, '$dir/projects/car');
      final kg = a.taskByUid('AB2-CD3')!.$2;
      expect(kg.name, 'Insurance');
      expect(kg.dir, '$dir/projects/car/AB2-CD3-insurance');
      expect(kg.projectId, 'car');
      expect(kg.legacyId, 'T1');
      expect(kg.items.map((i) => i.done), [false, true]);
      expect(kg.conversation, hasLength(2));
      expect(kg.threads.single.archived, isTrue);
      expect(kg.activeThread, isNull);
      expect(a.taskByUid('NPR-5TG')!.$2.activeThread!.id, 'live-session');
    });

    test('derived views', () async {
      final a = await loadAgenda(dir);
      expect(a.needsUser.single.$2.uid, 'NPR-5TG');
      expect(a.watchedSenders, unorderedEquals(['insurer', 'roofer.example']));
      final up = a.upcoming(from: DateTime(2026, 9, 11));
      expect(up.map((d) => '${d.date} ${d.project} ${d.task}'),
          ['2026-09-12 house NPR-5TG', '2026-09-18 car AB2-CD3', '2026-12-31 car AB2-CD3']);
      expect(a.overdue(from: DateTime(2026, 9, 20)).map((d) => d.task), ['AB2-CD3', 'NPR-5TG']);
      expect(a.allThreadIds, {'old-session', 'live-session'});
      expect(a.threadById('live-session')!.$1, 'task:NPR-5TG');
      expect(a.threadsFor('task:AB2-CD3').single.id, 'old-session');
      expect(a.jsonPathForNode('project:car'), '$dir/projects/car/project.json');
      expect(a.jsonPathForNode('general'), '$dir/general.json');
      expect(a.jsonPathForNode('task:ZZZ-999'), isNull);
    });

    test('cancelled is not open', () {
      expect(TaskStatus.cancelled.isOpen, isFalse);
      expect(TaskStatus.done.isOpen, isFalse);
      expect(TaskStatus.waiting.isOpen, isTrue);
      expect(TaskStatus.parse('cancelled'), TaskStatus.cancelled);
      expect(TaskStatus.parse('bogus'), TaskStatus.todo);
    });

    test('broken files are reported, the rest still loads', () async {
      await File('$dir/projects/car/XY7-Q8W-letter/task.json').writeAsString('{ nope');
      await Directory('$dir/projects/car/QQQ-QQQ-mismatch').create();
      await File('$dir/projects/car/QQQ-QQQ-mismatch/task.json').writeAsString('{"uid": "AB2-CD3", "name": "dup"}');
      await Directory('$dir/projects/bad id').create();
      await File('$dir/projects/bad id/project.json').writeAsString('{}');
      final a = await loadAgenda(dir);
      expect(a.errors, hasLength(3));
      expect(a.errors.join('\n'), contains('not valid JSON'));
      expect(a.errors.join('\n'), contains('differs from the folder name'));
      expect(a.errors.join('\n'), contains('[A-Za-z0-9-]'));
      expect(a.allTasks.length, 2);
    });

    test('duplicate uid across projects', () async {
      await Directory('$dir/projects/house/AB2-CD3-copy').create();
      await File('$dir/projects/house/AB2-CD3-copy/task.json').writeAsString('{"uid": "AB2-CD3", "name": "copy"}');
      final a = await loadAgenda(dir);
      expect(a.errors.single, contains('duplicate uid'));
      expect(a.allTasks.length, 3);
    });

    test('missing projects folder throws', () {
      expect(() => loadAgenda('${tmp.path}/nowhere'), throwsA(isA<FileSystemException>()));
    });

    test('round trip keeps every field', () async {
      final a = await loadAgenda(dir);
      final t = a.taskByUid('AB2-CD3')!.$2;
      final again = AgendaTask.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, Object?>);
      expect(again.toJson(), t.toJson());
      final p = a.projectById('car')!;
      expect(Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>).toJson(), p.toJson());
    });
  });

  group('writers', () {
    Future<Map<String, Object?>> read(String path) async =>
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;

    test('updateTask keeps unknown fields and serialises writes', () async {
      final a = await loadAgenda(dir);
      final t = a.taskByUid('AB2-CD3')!.$2;
      await Future.wait([
        for (var i = 0; i < 5; i++) appendHistory(t.jsonPath, 'line $i', date: '2026-09-14'),
      ]);
      final j = await read(t.jsonPath);
      expect(j['extra_field'], 'kept');
      expect((j['history'] as List).length, 6);
      expect((j['history'] as List).last, {'date': '2026-09-14', 'text': 'line 4'});
      expect(await updateJsonFile('$dir/missing.json', (_) {}), isFalse);
    });

    test('status, file status, items', () async {
      var a = await loadAgenda(dir);
      var t = a.taskByUid('AB2-CD3')!.$2;
      await setTaskStatus(t, TaskStatus.inProgress);
      await setFileStatus(t, 'guide.md', 'approved');
      await setItemDone(t, '1', true);
      final id = await addItem(t, 'Post it');
      expect(id, '3');
      a = await loadAgenda(dir);
      t = a.taskByUid('AB2-CD3')!.$2;
      expect(t.status, TaskStatus.inProgress);
      expect(t.files.single.approved, isTrue);
      expect(t.items[0].done, isTrue);
      expect(t.items[0].doneAt, isNotNull);
      expect(t.items[2].text, 'Post it');
      expect(t.history.map((h) => h.text).join('\n'), contains('Status set to "In progress"'));
      expect(t.history.map((h) => h.text).join('\n'), contains('approved guide.md'));
      expect(t.history.map((h) => h.text).join('\n'), contains('Ticked item 1'));
    });

    test('conversation and threads', () async {
      var a = await loadAgenda(dir);
      final path = a.jsonPathForNode('task:NPR-5TG')!;
      await appendConversation(path, ConversationEntry(at: DateTime(2026, 9, 14, 10), role: 'user', text: 'hi', session: 'live-session'));
      await addThread(path, ThreadInfo(id: 'new-session', created: DateTime(2026, 9, 14, 11)));
      a = await loadAgenda(dir);
      var t = a.taskByUid('NPR-5TG')!.$2;
      expect(t.conversation.single.text, 'hi');
      expect(t.threads.map((x) => x.id), ['live-session', 'new-session']);

      await archiveThread(path, 'live-session', 'reshaped');
      a = await loadAgenda(dir);
      t = a.taskByUid('NPR-5TG')!.$2;
      expect(t.threads.first.archived, isTrue);
      expect(t.threads.first.archivedReason, 'reshaped');
      expect(a.activeThread('task:NPR-5TG')!.id, 'new-session');

      await restoreThread(path, 'live-session');
      a = await loadAgenda(dir);
      t = a.taskByUid('NPR-5TG')!.$2;
      // Threads run in parallel: restoring one leaves the others open.
      expect(t.threads.every((x) => !x.archived), isTrue);
      expect(a.activeThread('task:NPR-5TG')!.id, 'new-session');
    });

    test('general.json is created on first write', () async {
      await File('$dir/general.json').delete();
      await updateGeneral(dir, (j) => (j['threads'] as List).add({'id': 'g1', 'created': '2026-09-14T00:00:00'}));
      final a = await loadAgenda(dir);
      expect(a.general.threads.single.id, 'g1');
      expect(await updateNode(a, 'task:ZZZ-999', (_) {}), isFalse);
      expect(await updateNode(a, 'project:car', (j) => j['status'] = 'x'), isTrue);
    });

    test('createProject and createTask', () async {
      final p = await createProject(agendaDir: dir, id: 'bike', title: 'Bike');
      expect(await Directory('$dir/projects/bike/sources').exists(), isTrue);
      expect(await Directory('$dir/projects/bike/data').exists(), isTrue);
      final t = await createTask(project: p, name: 'Renew the TÜV', due: '2026-10-01');
      expect(t.dir, startsWith('$dir/projects/bike/'));
      expect(t.dir.split('/').last, endsWith('-renew-the-tuev'));
      expect(isValidUid(t.uid), isTrue);
      final a = await loadAgenda(dir);
      expect(a.errors, isEmpty);
      expect(a.taskByUid(t.uid)!.$2.due, '2026-10-01');
      expect(a.taskByUid(t.uid)!.$2.created, isNotNull);
      expect(() => createProject(agendaDir: dir, id: 'car', title: 'x'), throwsStateError);
      expect(() => createProject(agendaDir: dir, id: 'bad id', title: 'x'), throwsArgumentError);
      final taken = await takenUids('$dir/projects');
      expect(taken, containsAll(['AB2-CD3', 'XY7-Q8W', 'NPR-5TG', t.uid]));
    });

    test('validation', () async {
      final a = await loadAgenda(dir);
      final t = a.taskByUid('AB2-CD3')!.$2;
      expect(validateTaskJson(t.toJson()), isEmpty);
      expect(validateProjectJson(a.projectById('car')!.toJson()), isEmpty);
      final bad = validateTaskJson({'uid': 'nope', 'name': '', 'status': 'later', 'due': '18.09.2026', 'history': 'x'});
      expect(bad, hasLength(5));
      expect(validateProjectJson({'id': 'x y', 'title': 't', 'deadlines': [{'date': 'soon', 'task': 'T1'}]}), hasLength(3));
    });

    test('field edits, item removal and follow-ups', () async {
      var a = await loadAgenda(dir);
      final p = a.projectById('car')!;
      var t = a.taskByUid('AB2-CD3')!.$2;
      await editTaskFields(t, {'name': 'Insurance 2026', 'due': null, 'priority': 2});
      await removeItem(t, '2');
      expect(() => editTaskFields(t, {'uid': 'x'}), throwsArgumentError);
      a = await loadAgenda(dir);
      t = a.taskByUid('AB2-CD3')!.$2;
      expect(t.name, 'Insurance 2026');
      expect(t.due, isNull);
      expect(t.priority, 2);
      expect(t.items.map((i) => i.id), ['1']);
      expect(t.history.last.text, contains('Removed item 2'));

      final f = await spawnFollowUp(project: p, from: t, name: 'Post the application', moveOpenItems: true, due: '2026-09-25');
      a = await loadAgenda(dir);
      final follow = a.taskByUid(f.uid)!.$2;
      expect(follow.follows, 'AB2-CD3');
      expect(follow.items.single.text, 'Request the mileage');
      expect(follow.watch.single.from, 'Insurer');
      expect(follow.due, '2026-09-25');
      expect(follow.history.first.text, contains('follow-up of AB2-CD3'));
      final orig = a.taskByUid('AB2-CD3')!.$2;
      expect(orig.items, isEmpty);
      expect(orig.history.last.text, contains('Follow-up ${f.uid}'));
      expect(a.successorsOf('AB2-CD3').map((x) => x.uid), [f.uid]);
      expect(validateTaskJson(follow.toJson()), isEmpty);
      expect(validateTaskJson({...follow.toJson(), 'follows': 'nope'}), contains('follows must be a UID'));
    });
  });

  group('calendar', () {
    test('scheduled round trip and validation', () async {
      final t = (await loadAgenda(dir)).taskByUid('AB2-CD3')!.$2;
      expect(t.scheduled, isNull);
      await editTaskFields(t, {'scheduled': '2026-09-24T14:30'});
      final again = (await loadAgenda(dir)).taskByUid('AB2-CD3')!.$2;
      expect(again.scheduledAt, DateTime(2026, 9, 24, 14, 30));
      expect(again.scheduledHasTime, isTrue);
      expect(again.history.last.text, contains('scheduled'));
      final j = jsonDecode(File(again.jsonPath).readAsStringSync()) as Map<String, Object?>;
      expect(validateTaskJson(j), isEmpty);
      expect(validateTaskJson({...j, 'scheduled': '24.09.2026'}), isNotEmpty);
      expect(validateTaskJson({...j, 'scheduled': '2026-09-24'}), isEmpty);
    });

    test('events: add, update, remove, load, validate', () async {
      expect((await loadAgenda(dir)).events, isEmpty);
      final e = await addEvent(dir, AgendaEvent(id: '', date: '2026-09-25', time: '14:00', title: 'GP', project: 'house'));
      await addEvent(dir, AgendaEvent(id: '', date: '2026-09-24', title: 'Post office'));
      var a = await loadAgenda(dir);
      expect(a.errors, isEmpty);
      expect(a.events.map((x) => x.title), ['Post office', 'GP']);
      expect(a.events.last.start, DateTime(2026, 9, 25, 14));
      expect(a.upcoming(from: DateTime(2026, 9, 20)).map((d) => d.text), contains('14:00 GP'));
      await updateEvent(dir, AgendaEvent(id: e.id, date: '2026-09-26', title: 'GP moved'));
      await removeEvent(dir, a.events.first.id);
      a = await loadAgenda(dir);
      expect(a.events.single.title, 'GP moved');
      expect(a.events.single.time, isNull);
      expect(validateEventsJson({'events': [{'id': 'x', 'date': 'bad', 'title': '', 'time': '2pm'}]}), hasLength(3));
    });
  });

  group('recurring', () {
    test('topics and items: add, update, remove, load, validate', () async {
      expect((await loadAgenda(dir)).recurringTopics, isEmpty);
      final topic = await addRecurringTopic(dir, 'Campervan');
      expect(topic.id, 'campervan');
      final item = await addRecurringItem(
        dir,
        topic.id,
        RecurringItem(id: '', text: 'Yearly insurance', interval: RecurringInterval.yearly, anchor: '2026-03-15', nextDue: '2026-03-15'),
      );
      await addRecurringItem(
        dir,
        topic.id,
        RecurringItem(id: '', text: 'TUEV', interval: RecurringInterval.days, every: 90, anchor: '2026-01-01', nextDue: '2026-04-01'),
      );
      var a = await loadAgenda(dir);
      expect(a.errors, isEmpty);
      expect(a.recurringTopics.single.items.map((i) => i.text), ['Yearly insurance', 'TUEV']);
      expect(a.upcoming(from: DateTime(2026, 1, 1)).map((d) => d.text), containsAll(['Campervan: Yearly insurance', 'Campervan: TUEV']));

      await updateRecurringItem(dir, topic.id, RecurringItem(id: item.id, text: 'Yearly insurance (renewed)', anchor: item.anchor, nextDue: item.nextDue));
      await removeRecurringItem(dir, topic.id, a.recurringTopics.single.items.last.id);
      a = await loadAgenda(dir);
      expect(a.recurringTopics.single.items.single.text, 'Yearly insurance (renewed)');

      await renameRecurringTopic(dir, topic.id, 'The campervan');
      a = await loadAgenda(dir);
      expect(a.recurringTopics.single.title, 'The campervan');

      await removeRecurringTopic(dir, topic.id);
      expect((await loadAgenda(dir)).recurringTopics, isEmpty);

      expect(
        validateRecurringJson({
          'topics': [
            {
              'id': 'x',
              'title': '',
              'items': [
                {'id': '', 'text': '', 'interval': 'weekly', 'anchor': 'bad', 'next_due': 'bad'},
              ],
            },
          ],
        }),
        hasLength(6),
      );
    });

    test('markRecurringItemDone advances next_due from the previous due date and logs history', () async {
      final topic = await addRecurringTopic(dir, 'Campervan');
      final item = await addRecurringItem(
        dir,
        topic.id,
        RecurringItem(id: '', text: 'Yearly insurance', interval: RecurringInterval.yearly, anchor: '2026-03-15', nextDue: '2026-03-15'),
      );
      // Marked done a week late; the next due date still steps from the original next_due, not from today.
      await markRecurringItemDone(dir, topic.id, item.id, doneDate: '2026-03-22');
      final a = await loadAgenda(dir);
      final updated = a.recurringTopics.single.items.single;
      expect(updated.nextDue, '2027-03-15');
      expect(updated.lastDone, '2026-03-22');
      expect(updated.history.single.text, contains('2027-03-15'));
    });

    test('nextOccurrenceAfter: yearly, monthly (clamped), days', () {
      final yearly = RecurringItem(id: 'a', text: 't', interval: RecurringInterval.yearly, anchor: '2024-02-29', nextDue: '2024-02-29');
      expect(yearly.nextOccurrenceAfter('2024-02-29'), '2025-02-28'); // clamped, 2025 is not a leap year

      final everyTwoYears = RecurringItem(id: 'b', text: 't', interval: RecurringInterval.yearly, every: 2, anchor: '2026-03-15', nextDue: '2026-03-15');
      expect(everyTwoYears.nextOccurrenceAfter('2026-03-15'), '2028-03-15');

      final monthly = RecurringItem(id: 'c', text: 't', interval: RecurringInterval.monthly, anchor: '2026-01-31', nextDue: '2026-01-31');
      expect(monthly.nextOccurrenceAfter('2026-01-31'), '2026-02-28'); // Feb has 28 days in 2026
      expect(monthly.nextOccurrenceAfter('2026-02-28'), '2026-03-28');

      final days = RecurringItem(id: 'd', text: 't', interval: RecurringInterval.days, every: 90, anchor: '2026-01-01', nextDue: '2026-01-01');
      expect(days.nextOccurrenceAfter('2026-01-01'), '2026-04-01');
    });

    test('Agenda.upcoming() includes a near-due recurring item and excludes one far in the future', () async {
      final topic = await addRecurringTopic(dir, 'Campervan');
      await addRecurringItem(dir, topic.id, RecurringItem(id: '', text: 'Soon', interval: RecurringInterval.yearly, anchor: '2026-09-25', nextDue: '2026-09-25'));
      await addRecurringItem(dir, topic.id, RecurringItem(id: '', text: 'Later', interval: RecurringInterval.yearly, anchor: '2029-01-01', nextDue: '2029-01-01'));
      final a = await loadAgenda(dir);
      final texts = a.upcoming(from: DateTime(2026, 9, 20)).map((d) => d.text);
      expect(texts, contains('Campervan: Soon'));
      final past = a.upcoming(from: DateTime(2030, 1, 1)).map((d) => d.text);
      expect(past, isNot(contains('Campervan: Later')));
    });
  });
}
