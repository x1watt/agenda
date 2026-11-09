import 'dart:io';
import 'dart:math';

import 'package:agenda_core/agenda_core.dart';
import 'package:test/test.dart';

void main() {
  test('uid format and alphabet', () {
    final uid = generateUid({});
    expect(uid, matches(RegExp(r'^[A-Z2-9]{3}-[A-Z2-9]{3}$')));
    expect(uid, isNot(contains(RegExp('[IO01]'))));
    expect(isValidUid(uid), isTrue);
    expect(isValidUid('ABC-DEF-G'), isFalse);
    expect(isValidUid('abc-def'), isFalse);
    expect(isValidUid('AB1-CDE'), isFalse);
  });

  test('uid generation skips taken ids and is deterministic with a seed', () {
    final first = generateUid({}, rng: Random(7));
    expect(generateUid({}, rng: Random(7)), first);
    expect(generateUid({first}, rng: Random(7)), isNot(first));
    final many = {for (var i = 0; i < 500; i++) generateUid({}, rng: Random(i))};
    expect(many.length, greaterThan(490));
  });

  test('takenUids reads folder names and uid fields', () async {
    final tmp = Directory.systemTemp.createTempSync('agenda_ids');
    addTearDown(() => tmp.deleteSync(recursive: true));
    await Directory('${tmp.path}/car/AB2-CD3-broken').create(recursive: true);
    await File('${tmp.path}/car/AB2-CD3-broken/task.json').writeAsString('{ not json');
    await Directory('${tmp.path}/car/XY7-Q8W-fine').create(recursive: true);
    await File('${tmp.path}/car/XY7-Q8W-fine/task.json').writeAsString('{"uid": "XY7-Q8W"}');
    await Directory('${tmp.path}/car/sources').create(recursive: true);
    expect(await takenUids(tmp.path), {'AB2-CD3', 'XY7-Q8W'});
    expect(await takenUids('${tmp.path}/missing'), isEmpty);
  });

  test('slugFor', () {
    expect(slugFor('Insurance application for the second car'), 'insurance-application-for-the-second-car');
    expect(slugFor('Finanzamt: Rückfrage, Straße!'), 'finanzamt-rueckfrage-strasse');
    expect(slugFor('   '), 'task');
    expect(slugFor('A'), 'a');
    expect(slugFor('x' * 60).length, lessThanOrEqualTo(40));
    expect(taskFolderName('AB2-CD3', 'Hello World'), 'AB2-CD3-hello-world');
  });

  test('folder pattern and project ids', () {
    expect(uidOfFolder('AB2-CD3-hello-world'), 'AB2-CD3');
    expect(uidOfFolder('AB2-CD3'), isNull);
    expect(uidOfFolder('sources'), isNull);
    expect(uidOfFolder('ab2-cd3-x'), isNull);
    expect(isValidProjectId('house'), isTrue);
    expect(isValidProjectId('Car2026'), isTrue);
    expect(isValidProjectId('my project'), isFalse);
    expect(isValidProjectId('a_b'), isFalse);
    expect(isValidProjectId(''), isFalse);
  });

  test('path helpers', () {
    expect(normalizePath('/a/b/../c/./d'), '/a/c/d');
    expect(relativeTo('/a/b/agenda', '/a/b/car/post/x.md'), '../car/post/x.md');
    expect(relativeTo('/a/b/agenda', '/a/b/agenda/x.md'), 'x.md');
  });
}
