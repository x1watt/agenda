// Two devices of one account syncing through a real Reticulum hub.
// Needs the network, so it only runs when a hub is given:
//   AGENDA_HUB=rns.wisco.network:4242 flutter test test/rns_sync_test.dart
import 'dart:io';

import 'package:agenda/src/identity/identity.dart';
import 'package:agenda/src/sync_service.dart';
import 'package:agenda_core/agenda_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final hub = Platform.environment['AGENDA_HUB'];

  test('a file written on one device reaches the other through the hub, and back', () async {
    final tmp = Directory.systemTemp.createTempSync('agenda_rns');
    AgendaPaths.homeOverride = tmp.path;
    SyncService device(String name) {
      final s = AgendaSettings(agendaDir: '${tmp.path}/$name/agenda', personalDir: '${tmp.path}/$name/personal')
        ..deviceName = name
        ..syncHubs = [hub!];
      Directory('${s.agendaDir}/projects').createSync(recursive: true);
      Directory(s.personalDir).createSync(recursive: true);
      return SyncService(settings: s, onFilesChanged: () {}, keys: MemoryKeyStore());
    }

    final a = device('laptop'), b = device('phone');
    try {
      await a.start();
      // The phone installs the laptop's account before it starts.
      File('${b.settings.agendaDir}/accounts/agenda.nsec')
        ..createSync(recursive: true)
        ..writeAsStringSync(a.identity!.nsec);
      await b.start();
      expect(b.identity!.npub, a.identity!.npub);

      Future<void> until(bool Function() ok, String what) async {
        final end = DateTime.now().add(const Duration(minutes: 4));
        while (!ok()) {
          if (DateTime.now().isAfter(end)) fail('timed out: $what\n${a.node?.logLines.join('\n')}\n---\n${b.node?.logLines.join('\n')}');
          await Future<void>.delayed(const Duration(seconds: 3));
          await Future.wait([a.syncNow(), b.syncNow()]);
        }
      }

      await until(() => a.devices.isNotEmpty && b.devices.isNotEmpty, 'devices see each other');
      expect(a.devices.single.name, 'phone');

      File('${a.settings.personalDir}/me.md').writeAsStringSync('# Me, from the laptop');
      File('${a.settings.agendaDir}/accounts/mail.pass').writeAsStringSync('secret');
      final onPhone = File('${b.settings.personalDir}/me.md');
      await until(() => onPhone.existsSync(), 'file reaches the phone');
      expect(onPhone.readAsStringSync(), '# Me, from the laptop');
      await until(() => File('${b.settings.agendaDir}/accounts/mail.pass').existsSync(), 'credential reaches the phone');

      File('${b.settings.personalDir}/from-phone.md').writeAsStringSync('photo note');
      await until(() => File('${a.settings.personalDir}/from-phone.md').existsSync(), 'file comes back to the laptop');
    } finally {
      await a.stop();
      await b.stop();
      tmp.deleteSync(recursive: true);
    }
  }, skip: hub == null ? 'set AGENDA_HUB=host:port to run against a real hub' : false, timeout: const Timeout(Duration(minutes: 10)));
}
