// One-off: save the attachments of one INBOX message to a folder.
// usage (from agenda/core): dart run tool/save_attachments.dart <uid> <outdir> [folder]
import 'dart:io';
import 'package:enough_mail/enough_mail.dart';
import 'package:agenda_core/agenda_core.dart';

Future<void> main(List<String> argv) async {
  final uid = int.parse(argv[0]);
  final outDir = Directory(argv[1])..createSync(recursive: true);
  final settings = await AgendaSettings.load();
  final account = await BridgeAccount.load(settings.paths.accountsDir);
  final password =
      (await File('${settings.paths.accountsDir}/protonmail-bridge.pass').readAsString()).trim();
  SecurityContext.defaultContext
      .setTrustedCertificates('${settings.paths.accountsDir}/protonmail-bridge-cert.pem');
  final client = ImapClient(isLogEnabled: false);
  await client.connectToServer('127.0.0.1', 1143, isSecure: false);
  await client.startTls();
  await client.login(account.address, password);
  final boxes = await client.listMailboxes(recursive: true);
  await client.examineMailbox(boxes.firstWhere((b) => b.path == 'INBOX'));
  final r = await client.uidFetchMessage(uid, 'BODY.PEEK[]');
  final m = r.messages.first;
  for (final c in m.findContentInfo(disposition: ContentDisposition.attachment)) {
    final part = m.getPart(c.fetchId);
    final data = part?.decodeContentBinary();
    final name = c.fileName ?? 'part-${c.fetchId}';
    if (data == null) {
      print('could not decode $name');
      continue;
    }
    final f = File('${outDir.path}/$name');
    f.writeAsBytesSync(data);
    print('saved ${f.path} (${data.length} bytes)');
  }
  try {
    await client.logout().timeout(const Duration(seconds: 5));
  } catch (_) {
    // Bridge sometimes never answers the logout; the files are already written.
  }
  exit(0);
}
