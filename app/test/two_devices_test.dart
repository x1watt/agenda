// Two complete app instances of one account (a laptop with an agenda, a fresh
// phone that joins with the laptop's key) updating each other through a real
// Reticulum hub. Nothing calls "sync now": changes travel only through the
// app's own triggers (file watchers -> syncSoon -> sync or poke).
// Needs the network:
//   AGENDA_HUB=rns.wisco.network:4242 flutter test test/two_devices_test.dart
import 'dart:io';

import 'package:agenda/src/app_controller.dart';
import 'package:agenda/src/identity/identity.dart';
import 'package:agenda/src/secrets.dart';
import 'package:agenda_core/agenda_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  final hub = Platform.environment['AGENDA_HUB'];

  test('two devices keep each other up to date', () async {
    final tmp = Directory.systemTemp.createTempSync('agenda_two');
    AgendaPaths.homeOverride = tmp.path;
    final laptopDir = await writeFixtureAgenda(Directory('${tmp.path}/laptop')..createSync());
    final phoneDir = '${tmp.path}/phone/agenda';

    AppController device(String name, String agendaDir) => AppController(
      AgendaSettings(agendaDir: agendaDir, personalDir: '${tmp.path}/$name/personal')
        ..deviceName = name
        ..syncHubs = [hub!],
      syncKeys: MemoryKeyStore(),
    );

    final laptop = device('laptop', laptopDir);
    final phone = device('phone', phoneDir);
    final log = <String>[];

    Future<void> until(String what, bool Function() ok, {Duration within = const Duration(minutes: 3)}) async {
      final started = DateTime.now();
      while (!ok()) {
        if (DateTime.now().difference(started) > within) {
          fail('timed out: $what\n--- laptop\n${laptop.sync.node?.logLines.join('\n')}\n--- phone\n${phone.sync.node?.logLines.join('\n')}');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      log.add('${DateTime.now().difference(started).inSeconds.toString().padLeft(3)} s  $what');
    }

    AgendaTask? task(AppController app, String uid) => app.agenda?.taskByUid(uid)?.$2;

    try {
      await laptop.start();
      await until('laptop account ready', () => laptop.sync.identity != null);
      // The phone installs the laptop's account key (Settings > Use an existing account).
      File('$phoneDir/accounts/agenda.nsec')
        ..createSync(recursive: true)
        ..writeAsStringSync('${laptop.sync.identity!.nsec}\n');
      await phone.start();

      // 1. The new phone receives the whole agenda.
      await until('phone receives the agenda', () => task(phone, 'AB2-CD3') != null && (phone.agenda?.projects.length ?? 0) == 2);

      // 2. A task created on the laptop appears on the phone.
      final car = laptop.agenda!.projectById('car')!;
      final created = await laptop.createTask(car, name: 'Book the inspection', due: '2026-12-01');
      await until('new laptop task reaches the phone', () => task(phone, created.uid)?.name == 'Book the inspection');

      // 3. An item ticked on the phone is ticked on the laptop.
      final pt = task(phone, 'AB2-CD3')!;
      await phone.toggleItem(pt, pt.items.firstWhere((i) => i.id == '1'));
      await until('phone tick reaches the laptop', () => task(laptop, 'AB2-CD3')!.items.firstWhere((i) => i.id == '1').done);

      // 4. Both change the same task at the same moment: both changes survive on both.
      await Future.wait([
        laptop.setTaskStatus(task(laptop, 'AB2-CD3')!, TaskStatus.waiting),
        phone.addTaskItem(task(phone, 'AB2-CD3')!, 'Call the garage'),
      ]);
      bool merged(AppController app) {
        final t = task(app, 'AB2-CD3');
        return t != null && t.status == TaskStatus.waiting && t.items.any((i) => i.text == 'Call the garage');
      }

      await until('concurrent edits merged on both', () => merged(laptop) && merged(phone));

      // 5. An event added on the phone shows in the laptop's calendar.
      await phone.saveEvent(AgendaEvent(id: '', date: '2026-12-02', time: '09:00', title: 'Dentist'));
      await until('phone event reaches the laptop', () => laptop.agenda!.events.any((e) => e.title == 'Dentist'));

      // 6. A photo taken on the phone lands in the laptop's task folder.
      final photo = File('${tmp.path}/camera.jpg')..writeAsBytesSync(List.generate(300000, (i) => i % 251));
      final rel = await phone.addFileToTask(task(phone, 'AB2-CD3')!, photo.path, name: 'mileage');
      final onLaptop = File('${task(laptop, 'AB2-CD3')!.dir}/$rel');
      await until('300 KB photo reaches the laptop', () => onLaptop.existsSync() && onLaptop.lengthSync() == 300000);
      expect(onLaptop.readAsBytesSync(), photo.readAsBytesSync());

      // 7. Automation settings and credentials set on the laptop reach the phone.
      laptop.settings.model = 'opus';
      await laptop.saveSettings();
      await Secrets.setApiKey(laptop.settings, 'sk-ant-test-key');
      await until('shared model reaches the phone', () => phone.settings.model == 'opus');
      String? phoneKey;
      await until('API key reaches the phone', () {
        Secrets.apiKey(phone.settings).then((k) => phoneKey = k);
        return phoneKey == 'sk-ant-test-key';
      });
      if (Platform.isLinux) {
        expect(File(phone.settings.paths.apiKeyFile).statSync().modeString(), 'rw-------');
      }

      // 8. A task deleted on the laptop disappears from the phone.
      Directory(created.dir).deleteSync(recursive: true);
      await until('deleted task leaves the phone', () => task(phone, created.uid) == null);

      // No conflict copies anywhere.
      final copies = [
        for (final d in [laptopDir, phoneDir])
          for (final e in Directory(d).listSync(recursive: true))
            if (e.path.contains('.conflict-')) e.path,
      ];
      expect(copies, isEmpty);
      // ignore: avoid_print
      print('timings (each step from its action):\n${log.join('\n')}');
    } finally {
      await laptop.shutdown();
      await phone.shutdown();
      laptop.dispose();
      phone.dispose();
      tmp.deleteSync(recursive: true);
    }
  }, skip: hub == null ? 'set AGENDA_HUB=host:port to run against a real hub' : false, timeout: const Timeout(Duration(minutes: 20)));
}
