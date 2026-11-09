import 'dart:io';

import 'package:agenda/src/app_controller.dart';
import 'package:agenda/src/task_files.dart';
import 'package:agenda/src/ui/theme.dart';
import 'package:agenda/src/ui/home.dart';
import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  late Directory tmp;
  late String dir;
  late Agenda agenda;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agenda_files');
    dir = await writeFixtureAgenda(tmp);
    agenda = await loadAgenda(dir);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('mentioned paths', () {
    final m = mentionedPaths('Send ../car/post/Email-X.md, see INSURANCE.md and insurance/forms/ now. www.example.de')
        .toList();
    expect(m, containsAll(['../car/post/Email-X.md', 'INSURANCE.md', 'insurance/forms/']));
    expect(m.any((s) => s.contains('example.de')), isFalse);
  });

  test('task folder files, explicit refs, mentions, exclusions', () async {
    final (p, t) = agenda.taskByUid('AB2-CD3')!;
    await File('${t.dir}/notes.md').writeAsString('x');
    await File('${p.dir}/data/insurance/INSURANCE.md').create(recursive: true);
    await File('$dir/accounts/secret.md').create(recursive: true);
    final files = await resolveTaskFiles(
      agendaDir: dir,
      project: p,
      task: t,
      extraTexts: ['see INSURANCE.md and data/TASKS.md, also accounts/secret.md and project.json'],
    );
    final names = files.map((f) => f.name).toList();
    expect(names, containsAll(['guide.md', 'notes.md', 'INSURANCE.md', 'TASKS.md']));
    expect(names, isNot(contains('secret.md')));
    expect(names, isNot(contains('task.json')));
    expect(names, isNot(contains('project.json')));
    final guide = files.singleWhere((f) => f.name == 'guide.md');
    expect(guide.rel, 'guide.md');
    expect(guide.ref, isNotNull);
    expect(files.singleWhere((f) => f.name == 'TASKS.md').rel, '../data/TASKS.md');
  });

  test('a symlinked path resolves to one file', () async {
    final ws = tmp.path;
    await Link('$ws/car').create('agenda/projects/car');
    final (p, t) = agenda.taskByUid('AB2-CD3')!;
    final files = await resolveTaskFiles(
      agendaDir: dir,
      project: p,
      task: t,
      extraTexts: ['../car/AB2-CD3-insurance/guide.md'],
    );
    expect(files.where((f) => f.name == 'guide.md'), hasLength(1));
  });

  test('approval tracks later edits', () {
    final at = DateTime(2026, 9, 11, 18);
    final ref = TaskFileRef(path: 'x.md', status: 'approved', at: at.toIso8601String());
    TaskFile file(DateTime modified) => TaskFile(path: '/x.md', rel: 'x.md', isDir: false, modified: modified, ref: ref);
    expect(file(DateTime(2026, 9, 11, 17)).approved, isTrue);
    expect(file(DateTime(2026, 9, 11, 19)).approved, isFalse);
    expect(file(DateTime(2026, 9, 11, 19)).changedSinceApproval, isTrue);
  });

  testWidgets('file pane renders', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppController(AgendaSettings(agendaDir: dir))..agenda = agenda;
    final (_, t) = agenda.taskByUid('NPR-5TG')!;
    File('${t.dir}/note.md').writeAsStringSync('# note');
    final f = TaskFile(path: '${t.dir}/note.md', rel: 'note.md', isDir: false, modified: DateTime(2026, 9, 11));
    app.taskFiles[taskNode(t)] = [f];
    app.selected = fileNode(t, f);
    await tester.pumpWidget(MaterialApp(theme: Ui.theme(), home: Home(app: app)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('note.md'), findsWidgets);
  });
}
