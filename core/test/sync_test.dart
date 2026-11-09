import 'dart:convert';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:test/test.dart';

Map<String, Object?> _task({String status = 'todo', List<Map<String, Object?>> items = const [], List<Map<String, Object?>> history = const []}) => {
  'version': 1,
  'uid': 'AB2-CD3',
  'name': 'Insurance',
  'status': status,
  'items': items,
  'history': history,
};

void main() {
  group('mergeJson', () {
    test('one side changed: take it', () {
      final r = mergeJson({'a': 1, 'b': 1}, {'a': 2, 'b': 1}, {'a': 1, 'b': 1}, localWins: false);
      expect(r.value, {'a': 2, 'b': 1});
      expect(r.conflicts, isEmpty);
    });

    test('different keys changed on each side', () {
      final r = mergeJson(_task(), _task(status: 'done'), {..._task(), 'due': '2026-10-01'}, localWins: false);
      expect((r.value as Map)['status'], 'done');
      expect((r.value as Map)['due'], '2026-10-01');
      expect(r.conflicts, isEmpty);
    });

    test('same scalar changed differently: newer wins, conflict noted', () {
      final r = mergeJson(_task(), _task(status: 'done'), _task(status: 'waiting'), localWins: false);
      expect((r.value as Map)['status'], 'waiting');
      expect(r.conflicts.single, contains('/status'));
    });

    test('items merged by id: tick on one side, new item on the other', () {
      final base = _task(items: [
        {'id': '1', 'text': 'a', 'done': false},
      ]);
      final local = _task(items: [
        {'id': '1', 'text': 'a', 'done': true},
      ]);
      final remote = _task(items: [
        {'id': '1', 'text': 'a', 'done': false},
        {'id': '2', 'text': 'b', 'done': false},
      ]);
      final r = mergeJson(base, local, remote, localWins: true);
      expect((r.value as Map)['items'], [
        {'id': '1', 'text': 'a', 'done': true},
        {'id': '2', 'text': 'b', 'done': false},
      ]);
      expect(r.conflicts, isEmpty);
    });

    test('item removed on one side, untouched on the other: removed', () {
      final base = _task(items: [
        {'id': '1', 'text': 'a'},
        {'id': '2', 'text': 'b'},
      ]);
      final local = _task(items: [
        {'id': '1', 'text': 'a'},
      ]);
      final r = mergeJson(base, local, base, localWins: false);
      expect(((r.value as Map)['items'] as List).length, 1);
    });

    test('history from both sides is kept, in date order', () {
      final base = _task(history: [
        {'date': '2026-09-20', 'text': 'x'},
      ]);
      final local = _task(history: [
        {'date': '2026-09-20', 'text': 'x'},
        {'date': '2026-09-25', 'text': 'phone'},
      ]);
      final remote = _task(history: [
        {'date': '2026-09-20', 'text': 'x'},
        {'date': '2026-09-24', 'text': 'desktop'},
      ]);
      final r = mergeJson(base, local, remote, localWins: true);
      expect(((r.value as Map)['history'] as List).map((h) => (h as Map)['text']), ['x', 'desktop', 'phone']);
    });

    test('no base (first sync): union of both', () {
      final r = mergeJson(const {}, {'a': 1}, {'b': 2}, localWins: true);
      expect(r.value, {'a': 1, 'b': 2});
    });
  });

  group('SyncRoots', () {
    test('agenda includes projects and the two root files only', () {
      expect(SyncRoots.includes('agenda', 'projects/car/AB2-CD3-x/task.json'), isTrue);
      expect(SyncRoots.includes('agenda', 'events.json'), isTrue);
      expect(SyncRoots.includes('agenda', 'recurring.json'), isTrue);
      expect(SyncRoots.includes('agenda', 'accounts/secret.md'), isFalse);
      expect(SyncRoots.includes('agenda', 'runs/1.json'), isFalse);
      expect(SyncRoots.includes('agenda', 'projects/../accounts/x'), isFalse);
      expect(SyncRoots.includes('agenda', 'projects/t/task.json.tmp-12'), isFalse);
      expect(SyncRoots.includes('personal', 'documents/a.pdf'), isTrue);
    });
  });

  group('client and server', () {
    late Directory tmp;
    late String desk, phone, state;
    late SyncServer server;
    late SyncClient client;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('agenda_sync');
      desk = '${tmp.path}/desk';
      phone = '${tmp.path}/phone';
      state = '${tmp.path}/state';
      Directory('$desk/agenda/projects/car/AB2-CD3-kg').createSync(recursive: true);
      Directory('$desk/agenda/accounts').createSync(recursive: true);
      Directory('$desk/personal').createSync(recursive: true);
      File('$desk/agenda/projects/car/AB2-CD3-kg/task.json').writeAsStringSync(encodeJson(_task(items: [
        {'id': '1', 'text': 'a', 'done': false},
      ])));
      File('$desk/agenda/accounts/secret.pass').writeAsStringSync('nope');
      File('$desk/personal/me.md').writeAsStringSync('# Me');
      final (cert, key) = await ensureCertificate('${tmp.path}/cert');
      server = SyncServer(
        roots: {'agenda': '$desk/agenda', 'personal': '$desk/personal'},
        name: 'desk',
        certPath: cert,
        keyPath: key,
        devicesFile: '${tmp.path}/devices.json',
        port: 0,
        discoveryPort: 0,
        apiKey: () async => 'sk-test',
      );
      await server.start();
      final code = server.startPairing();
      final (peer, apiKey) = await pairWithDesktop('127.0.0.1', server.boundPort, code, 'phone');
      expect(apiKey, 'sk-test');
      client = SyncClient(peer: peer, roots: {'agenda': '$phone/agenda', 'personal': '$phone/personal'}, stateDir: state, deviceName: 'phone');
    });

    tearDown(() async {
      await server.stop();
      tmp.deleteSync(recursive: true);
    });

    test('wrong code is refused', () async {
      server.startPairing();
      await expectLater(pairWithDesktop('127.0.0.1', server.boundPort, '000000', 'x'), throwsA(isA<SyncException>()));
    });

    test('first sync pulls everything except credentials', () async {
      final r = await client.sync();
      expect(r.errors, isEmpty);
      expect(File('$phone/agenda/projects/car/AB2-CD3-kg/task.json').existsSync(), isTrue);
      expect(File('$phone/personal/me.md').readAsStringSync(), '# Me');
      expect(File('$phone/agenda/accounts/secret.pass').existsSync(), isFalse);
      expect((await client.sync()).changes, 0);
    });

    test('a photo taken on the phone lands on the desktop; deletes propagate', () async {
      await client.sync();
      final photo = File('$phone/agenda/projects/car/AB2-CD3-kg/photos/2026-09-25_1400.jpg')..createSync(recursive: true);
      photo.writeAsBytesSync(List.generate(5000, (i) => i % 251));
      final r = await client.sync();
      expect(r.pushed, 1);
      expect(File('$desk/agenda/projects/car/AB2-CD3-kg/photos/2026-09-25_1400.jpg').readAsBytesSync(), photo.readAsBytesSync());
      File('$desk/agenda/projects/car/AB2-CD3-kg/photos/2026-09-25_1400.jpg').deleteSync();
      expect((await client.sync()).deletedHere, 1);
      expect(photo.existsSync(), isFalse);
    });

    test('task.json changed on both sides is merged', () async {
      await client.sync();
      final deskFile = File('$desk/agenda/projects/car/AB2-CD3-kg/task.json');
      final phoneFile = File('$phone/agenda/projects/car/AB2-CD3-kg/task.json');
      deskFile.writeAsStringSync(encodeJson(_task(items: [
        {'id': '1', 'text': 'a', 'done': false},
        {'id': '2', 'text': 'from desktop', 'done': false},
      ])));
      phoneFile.writeAsStringSync(encodeJson(_task(items: [
        {'id': '1', 'text': 'a', 'done': true},
      ])));
      final r = await client.sync();
      expect(r.merged, 1, reason: '${r.errors}');
      for (final f in [deskFile, phoneFile]) {
        final items = (jsonDecode(f.readAsStringSync()) as Map)['items'] as List;
        expect(items.map((i) => '${(i as Map)['id']}:${i['done']}'), ['1:true', '2:false']);
      }
      expect((await client.sync()).changes, 0);
    });

    test('binary changed on both sides keeps both versions', () async {
      File('$desk/personal/scan.jpg').writeAsBytesSync([1, 2, 3]);
      await client.sync();
      File('$desk/personal/scan.jpg').writeAsBytesSync([4, 5, 6]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File('$phone/personal/scan.jpg').writeAsBytesSync([7, 8, 9]);
      final r = await client.sync();
      expect(r.conflicts, hasLength(1));
      await client.sync(); // pushes the conflict copy
      final names = Directory('$desk/personal').listSync().map((e) => e.path.split('/').last).toList();
      expect(names.where((n) => n.startsWith('scan.conflict-')), hasLength(1));
      expect(File('$desk/personal/scan.jpg').readAsBytesSync(), [7, 8, 9]);
    });

    test('a text file changed on both sides keeps both versions', () async {
      await client.sync();
      File('$phone/personal/me.md').writeAsStringSync('# Me, phone');
      File('$desk/personal/me.md').writeAsStringSync('# Me, desk');
      final r = await client.sync();
      expect(r.conflicts, hasLength(1));
      await client.sync();
      expect(Directory('$desk/personal').listSync().where((e) => e.path.contains('me.conflict-')), hasLength(1));
    });

    test('unpaired token is refused', () async {
      await server.revoke(client.peer.token);
      final r = await client.sync();
      expect(r.errors.single, contains('no longer paired'));
    });
  });
}
