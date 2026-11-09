import 'dart:convert';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('agenda_multi'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('checker lock', () {
    final t0 = DateTime(2026, 11, 9, 10);
    const lease = Duration(minutes: 65);

    test('a free lock is taken and renewed by its holder', () async {
      final path = '${tmp.path}/shared/checker-lock.json';
      expect(await CheckerLock.take(path, device: 'a', name: 'desk', lease: lease, now: t0), isNull);
      expect(await CheckerLock.take(path, device: 'a', name: 'desk', lease: lease, now: t0.add(const Duration(minutes: 30))), isNull);
      final j = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(DateTime.parse('${j['until']}'), t0.add(const Duration(minutes: 95)));
    });

    test('another device steps back while the lease runs, takes over after', () async {
      final path = '${tmp.path}/checker-lock.json';
      await CheckerLock.take(path, device: 'a', name: 'desk', lease: lease, now: t0);
      final held = await CheckerLock.take(path, device: 'b', name: 'laptop', lease: lease, now: t0.add(const Duration(minutes: 64)));
      expect(held?.name, 'desk');
      expect(await CheckerLock.take(path, device: 'b', name: 'laptop', lease: lease, now: t0.add(const Duration(minutes: 66))), isNull);
      expect((await CheckerLock.take(path, device: 'a', name: 'desk', lease: lease, now: t0.add(const Duration(minutes: 70))))?.name, 'laptop');
    });

    test('a broken lock file is a free lock', () async {
      final path = '${tmp.path}/checker-lock.json';
      File(path).writeAsStringSync('{nope');
      expect(await CheckerLock.take(path, device: 'b', name: 'laptop', lease: lease, now: t0), isNull);
    });
  });

  group('checker state', () {
    test('shared part goes to the synced file, the device part stays local', () async {
      final local = '${tmp.path}/state.json', shared = '${tmp.path}/shared/checker-state.json';
      final s = CheckState(bootId: 'boot', lastCheck: DateTime(2026, 11, 9), lastFullRun: DateTime(2026, 11, 8), seen: {'INBOX:1'}, notifiedDeadlines: {'d1'});
      await s.save(sharedFile: shared, localFile: local);
      final l = jsonDecode(File(local).readAsStringSync()) as Map;
      final sh = jsonDecode(File(shared).readAsStringSync()) as Map;
      expect(l.keys, unorderedEquals(['boot_id', 'last_check']));
      expect(sh['seen'], ['INBOX:1']);
      final back = await CheckState.load(sharedFile: shared, localFile: local);
      expect(back.bootId, 'boot');
      expect(back.lastFullRun, DateTime(2026, 11, 8));
      expect(back.notifiedDeadlines, {'d1'});
    });

    test('before the shared file exists, the old single file provides everything', () async {
      final local = '${tmp.path}/state.json';
      await CheckState(bootId: 'b', seen: {'INBOX:7'}).save(localFile: local);
      final back = await CheckState.load(sharedFile: '${tmp.path}/missing.json', localFile: local);
      expect(back.seen, {'INBOX:7'});
    });

    test('mail seen and deadlines announced on two devices are united by the merge', () {
      final base = {'version': 1, 'seen': ['INBOX:1'], 'notified_deadlines': <String>[]};
      final a = {'version': 1, 'seen': ['INBOX:1', 'INBOX:2'], 'notified_deadlines': ['x']};
      final b = {'version': 1, 'seen': ['INBOX:1', 'INBOX:3'], 'notified_deadlines': ['y']};
      final r = mergeJson(base, a, b, localWins: true);
      expect(((r.value as Map)['seen'] as List).toSet(), {'INBOX:1', 'INBOX:2', 'INBOX:3'});
      expect(((r.value as Map)['notified_deadlines'] as List).toSet(), {'x', 'y'});
      expect(r.conflicts, isEmpty);
    });
  });

  group('shared settings', () {
    test('model and review hour come from the shared file; a stale device does not undo a change', () async {
      final agenda = '${tmp.path}/agenda';
      final fileA = '${tmp.path}/a.json', fileB = '${tmp.path}/b.json';
      final a = AgendaSettings(agendaDir: agenda)..model = 'opus';
      await a.save(file: fileA);
      final b2 = AgendaSettings(agendaDir: agenda);
      await b2.reloadShared();
      expect(b2.model, 'opus');
      // a changes the review hour; b (loaded before) saves an unrelated local setting.
      a.dailyRunHour = 9;
      await a.save(file: fileA);
      b2.calendarSplit = 0.4;
      await b2.save(file: fileB);
      final shared = jsonDecode(File('$agenda/shared/settings.json').readAsStringSync()) as Map;
      expect(shared['daily_run_hour'], 9);
      expect(shared['model'], 'opus');
      final reloaded = await AgendaSettings.load(file: fileB);
      expect(reloaded.calendarSplit, 0.4);
    });
  });

  test('localDeviceId is made once and kept', () async {
    final f = '${tmp.path}/device-id';
    final id = await localDeviceId(file: f);
    expect(id, hasLength(16));
    expect(await localDeviceId(file: f), id);
  });
}
