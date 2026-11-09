import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agenda_core/agenda_core.dart';
import 'package:test/test.dart';

import 'fixture.dart';

/// The source-folder mapping of the fixture workspace (see [defaultSourceFolders]).
const _sources = <String, List<String>>{
  'car': ['invoices', 'insurance/forms', 'insurance/receipts', 'insurance/letters'],
  'house': [],
};

void main() {
  late Directory tmp;
  late String dir;
  late String ws;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agenda_migrate');
    dir = await writeLegacyWorkspace(tmp);
    ws = tmp.path;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Map<String, Object?>> read(String path) async => jsonDecode(await File(path).readAsString()) as Map<String, Object?>;

  test('dry run plans and changes nothing', () async {
    final r = await migrateLegacy(agendaDir: dir, dryRun: true, rng: Random(1), sourceFolders: _sources);
    expect(r.applied, isFalse);
    expect(r.taskCount, 3);
    expect(r.idMap['project:health'], 'house');
    expect(r.idMap['car/T19-23'], isNotNull);
    expect(r.moves.keys, contains('$ws/car/insurance/form-help.md'));
    expect(await Directory('$dir/projects').exists(), isFalse);
    expect(await File('$dir/tasks.json').exists(), isTrue);
    expect(await Directory('$ws/car').exists(), isTrue);
    expect(r.log.join('\n'), contains('Dry run'));
  });

  test('applies: folders, moves, symlinks, json, legacy, links', () async {
    final r = await migrateLegacy(
        agendaDir: dir, rng: Random(1), now: DateTime(2026, 9, 14, 12), sourceFolders: _sources);
    expect(r.applied, isTrue);
    final t1 = r.idMap['car/T1']!;
    final t19 = r.idMap['car/T19-23']!;
    final h1 = r.idMap['health/H1']!;

    // Old folders are symlinks into the agenda.
    expect(await FileSystemEntity.isLink('$ws/car'), isTrue);
    expect(await Link('$ws/car').target(), 'agenda/projects/car');
    expect(await File('$ws/car/data/TASKS.md').exists(), isTrue);
    expect(await FileSystemEntity.isLink('$ws/house'), isTrue);

    // Content sorted into sources/, data/ and task folders.
    final car = '$dir/projects/car';
    expect(await File('$car/sources/invoices/Invoice 2021.pdf').exists(), isTrue);
    expect(await File('$car/sources/insurance/forms/FORM1.pdf').exists(), isTrue);
    expect(await Directory('$car/sources/insurance/receipts').exists(), isTrue);
    expect(await File('$car/data/PLAN.md').exists(), isTrue);
    expect(await File('$car/data/insurance/INSURANCE.md').exists(), isTrue);
    expect(await File('$car/data/post/letter.pdf').exists(), isTrue);
    expect(await File('$car/$t1-insurance/form-help.md').exists(), isTrue);
    expect(await File('$dir/projects/house/$h1-roof-check/reply-roofer.md').exists(), isTrue);
    expect(await File('$dir/projects/house/data/email.md').exists(), isTrue);

    // JSON documents.
    final pj = await read('$car/project.json');
    expect(pj['id'], 'car');
    expect(pj['docs'], ['data/TASKS.md', 'data/PLAN.md']);
    expect(pj['created'], '2026-09-11T00:00:00');
    final deadlines = (pj['deadlines'] as List).cast<Map<String, Object?>>();
    expect(deadlines.map((d) => d['task']), [t1, null, null]);
    expect((pj['threads'] as List).single, containsPair('id', 's-p'));
    expect((pj['threads'] as List).single, isNot(contains('node')));

    final tj = await read('$car/$t1-insurance/task.json');
    expect(tj['uid'], t1);
    expect(tj['name'], 'Insurance');
    expect(tj['legacy_id'], 'T1');
    expect(tj['items'], isEmpty);
    expect(tj['conversation'], isEmpty);
    expect((tj['files'] as List).single, containsPair('path', 'form-help.md'));
    expect((tj['watch'] as List).single, {'from': 'Insurer'});
    final t19j = await read('$car/$t19-letter-to-the-dealer/task.json');
    expect(t19j['status'], 'done');
    expect(t19j['created'], '2026-09-14T12:00:00.000');
    final hj = await read('$dir/projects/house/$h1-roof-check/task.json');
    expect((hj['threads'] as List).single, containsPair('id', 's-h1'));
    final gj = await read('$dir/general.json');
    expect((gj['threads'] as List).map((t) => (t as Map)['id']), ['s-g', 's-t2']);
    expect(((gj['threads'] as List)[1] as Map)['archived_reason'], startsWith('orphan from task:car/T2'));

    // Legacy files and id map.
    expect(await File('$dir/tasks.json').exists(), isFalse);
    expect(await File('$dir/legacy/tasks.json').exists(), isTrue);
    expect(await File('$dir/legacy/threads.json').exists(), isTrue);
    expect(await File('$dir/legacy/next.md').exists(), isTrue);
    final map = await read('$dir/legacy/id-map.json');
    expect((map['projects'] as Map)['health'], 'house');
    expect(((map['tasks'] as Map)['health/H1'] as Map)['uid'], h1);

    // Links rewritten relative to the new locations.
    final tasksMd = await File('$car/data/TASKS.md').readAsString();
    expect(tasksMd, contains('[plan](PLAN.md)'));
    expect(tasksMd, contains('[INS](insurance/INSURANCE.md)'));
    expect(tasksMd, contains('../sources/insurance/forms/'));
    final kg = await File('$car/data/insurance/INSURANCE.md').readAsString();
    expect(kg, contains('[guide](../../$t1-insurance/form-help.md)'));
    expect(kg, contains('../../sources/insurance/forms/FORM1.pdf'));
    expect(kg, contains('[plan](../PLAN.md)'));
    final guide = await File('$car/$t1-insurance/form-help.md').readAsString();
    expect(guide, contains('[INS](../data/insurance/INSURANCE.md)'));
    expect(guide, contains('../sources/insurance/forms/'));
    final plan = await File('$car/data/PLAN.md').readAsString();
    expect(plan, contains('../sources/invoices/'));
    final health = await File('$dir/projects/house/data/repairs.md').readAsString();
    expect(health, contains('[antwort](../$h1-roof-check/reply-roofer.md)'));
    expect(health, contains('[email](email.md)'));
    expect(r.unmappedLinks.single, contains('../agenda/next.md'));

    // Warnings.
    expect(r.warnings.join('\n'), contains('T99'));
    expect(r.warnings.join('\n'), contains('no known project'));
    expect(r.warnings.join('\n'), contains('s-t2'));

    // The result loads cleanly.
    final a = await loadAgenda(dir);
    expect(a.errors, isEmpty);
    expect(a.needsUser.single.$2.legacyId, 'H1');
    expect(a.watchedSenders, unorderedEquals(['insurer', 'roofer.example']));
    expect(a.upcoming(from: DateTime(2026, 9, 11)).map((d) => d.date), ['2026-09-12', '2026-09-18', '2026-10-25', '2026-12-19', '2026-12-31']);

    // A second run refuses.
    expect(() => migrateLegacy(agendaDir: dir), throwsStateError);
  });

  test('refuses when a project folder is already a symlink', () async {
    await Directory('$ws/car').rename('$ws/car-real');
    await Link('$ws/car').create('car-real');
    expect(() => migrateLegacy(agendaDir: dir, dryRun: true), throwsStateError);
  });
}
