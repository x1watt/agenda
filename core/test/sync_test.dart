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
    test('agenda includes projects, credentials, prompts, shared state and the root files', () {
      expect(SyncRoots.includes('agenda', 'projects/car/AB2-CD3-x/task.json'), isTrue);
      expect(SyncRoots.includes('agenda', 'events.json'), isTrue);
      expect(SyncRoots.includes('agenda', 'recurring.json'), isTrue);
      expect(SyncRoots.includes('agenda', 'accounts/protonmail-bridge.pass'), isTrue);
      expect(SyncRoots.includes('agenda', 'prompts/review.md'), isTrue);
      expect(SyncRoots.includes('agenda', 'shared/checker-lock.json'), isTrue);
      expect(SyncRoots.includes('agenda', 'runs/1.json'), isFalse);
      expect(SyncRoots.includes('agenda', 'core/lib/x.dart'), isFalse);
      expect(SyncRoots.includes('agenda', 'projects/../runs/x'), isFalse);
      expect(SyncRoots.includes('agenda', 'projects/t/task.json.tmp-12'), isFalse);
      expect(SyncRoots.includes('personal', 'documents/a.pdf'), isTrue);
      expect(SyncRoots.isPrivate('agenda', 'accounts/x.pass'), isTrue);
      expect(SyncRoots.isPrivate('agenda', 'projects/a/task.json'), isFalse);
    });
  });

  group('sessions over the request protocol', () {
    late Directory tmp;

    /// A device: its two roots and its host.
    ({Map<String, String> roots, SyncHost host}) device(String name) {
      final roots = {'agenda': '${tmp.path}/$name/agenda', 'personal': '${tmp.path}/$name/personal'};
      for (final d in roots.values) {
        Directory(d).createSync(recursive: true);
      }
      return (roots: roots, host: SyncHost(roots: roots, chunkBytes: 1000));
    }

    /// [from] syncs with [to] as if over the network: requests and replies go through JSON.
    SyncSession session(String from, String to, {int chunk = 1000}) {
      final a = device(from), b = device(to);
      return SyncSession(
        transport: RequestTransport((req) async {
          final reply = await b.host.handle((jsonDecode(jsonEncode(req)) as Map).cast<String, Object?>());
          return (jsonDecode(jsonEncode(reply)) as Map).cast<String, Object?>();
        }, chunkBytes: chunk),
        roots: a.roots,
        stateDir: '${tmp.path}/$from/state/$to',
        deviceName: from,
        peerName: to,
      );
    }

    late String desk, phone;
    late SyncSession client;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('agenda_sync');
      desk = '${tmp.path}/desk';
      phone = '${tmp.path}/phone';
      Directory('$desk/agenda/projects/car/AB2-CD3-kg').createSync(recursive: true);
      Directory('$desk/agenda/accounts').createSync(recursive: true);
      Directory('$desk/agenda/runs').createSync(recursive: true);
      Directory('$desk/personal').createSync(recursive: true);
      File('$desk/agenda/projects/car/AB2-CD3-kg/task.json').writeAsStringSync(encodeJson(_task(items: [
        {'id': '1', 'text': 'a', 'done': false},
      ])));
      File('$desk/agenda/accounts/secret.pass').writeAsStringSync('mail password');
      File('$desk/agenda/runs/1.json').writeAsStringSync('{}');
      File('$desk/personal/me.md').writeAsStringSync('# Me');
      client = session('phone', 'desk');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('first sync pulls every synced file, credentials at mode 600, but no run logs', () async {
      final r = await client.sync();
      expect(r.errors, isEmpty);
      expect(File('$phone/agenda/projects/car/AB2-CD3-kg/task.json').existsSync(), isTrue);
      expect(File('$phone/personal/me.md').readAsStringSync(), '# Me');
      expect(File('$phone/agenda/accounts/secret.pass').readAsStringSync(), 'mail password');
      if (Platform.isLinux) {
        expect(File('$phone/agenda/accounts/secret.pass').statSync().modeString(), 'rw-------');
      }
      expect(File('$phone/agenda/runs/1.json').existsSync(), isFalse);
      expect((await client.sync()).changes, 0);
    });

    test('a photo taken on the phone lands on the desktop in chunks; deletes propagate', () async {
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

    test('a task deleted on one side leaves no empty folder on either side', () async {
      await client.sync();
      Directory('$desk/agenda/projects/car/AB2-CD3-kg').deleteSync(recursive: true);
      expect((await client.sync()).deletedHere, 1);
      expect(Directory('$phone/agenda/projects/car/AB2-CD3-kg').existsSync(), isFalse);
      expect(Directory('$phone/agenda/projects').existsSync(), isTrue, reason: 'top-level folders stay');
      final t = File('$phone/agenda/projects/car/ZZ2-ZZ3-x/task.json')..createSync(recursive: true);
      t.writeAsStringSync('{}');
      await client.sync();
      t.parent.deleteSync(recursive: true);
      expect((await client.sync()).deletedThere, 1);
      expect(Directory('$desk/agenda/projects/car/ZZ2-ZZ3-x').existsSync(), isFalse);
    });

    test('a large file pulled in chunks arrives intact', () async {
      final big = List.generate(12345, (i) => (i * 7) % 256);
      File('$desk/personal/scan.pdf').writeAsBytesSync(big);
      expect((await client.sync()).errors, isEmpty);
      expect(File('$phone/personal/scan.pdf').readAsBytesSync(), big);
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

    test('three devices converge pair by pair', () async {
      final laptop = session('laptop', 'desk');
      final phoneLaptop = session('phone', 'laptop');
      await client.sync();
      await laptop.sync();
      File('$phone/personal/from-phone.md').writeAsStringSync('p');
      File('${tmp.path}/laptop/personal/from-laptop.md').writeAsStringSync('l');
      await phoneLaptop.sync(); // phone <-> laptop
      await client.sync(); // phone <-> desk
      for (final d in ['desk', 'phone', 'laptop']) {
        expect(File('${tmp.path}/$d/personal/from-phone.md').existsSync(), isTrue, reason: d);
        expect(File('${tmp.path}/$d/personal/from-laptop.md').existsSync(), isTrue, reason: d);
      }
      expect((await laptop.sync()).changes, 0);
    });

    test('the host refuses paths outside the synced files', () async {
      final host = SyncHost(roots: {'agenda': '$desk/agenda'});
      expect((await host.handle({'op': 'get', 'root': 'agenda', 'path': 'runs/1.json'}))['error'], 'path not synced');
      expect((await host.handle({'op': 'get', 'root': 'agenda', 'path': 'projects/../runs/1.json'}))['error'], 'path not synced');
      expect((await host.handle({'op': 'manifest', 'root': 'etc'}))['error'], 'unknown root');
    });

    test('a write based on an old version is refused', () async {
      final host = SyncHost(roots: {'personal': '$desk/personal'});
      final t = RequestTransport((r) => host.handle(r));
      expect(await t.put('personal', 'me.md', [1], 'not-the-hash', 0), isFalse);
      expect(await t.put('personal', 'me.md', [1], null, 0), isFalse); // it exists
      expect(File('$desk/personal/me.md').readAsStringSync(), '# Me');
      expect(await t.delete('personal', 'me.md', 'not-the-hash'), isFalse);
    });

    test('an unreachable peer is reported, not thrown', () async {
      final s = SyncSession(
        transport: RequestTransport((_) async => throw SyncException('desk not reachable')),
        roots: device('phone').roots,
        stateDir: '${tmp.path}/x',
        deviceName: 'phone',
        peerName: 'desk',
      );
      expect((await s.sync()).errors.single, 'desk not reachable');
    });
  });
}
