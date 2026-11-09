/// Sends one plain text mail through the local Proton Mail Bridge.
///
/// Sending is always an explicit request by the user in a live session. The
/// background checker never calls this, and --confirm has to be passed by hand.
///
/// Usage (from agenda/):
///   dart run core/bin/send_mail.dart --to a@b.de [--cc c@d.de] \
///       --subject "..." --body-file draft.txt [--attach a.pdf,b.pdf] [--confirm]
///
/// Without --confirm it only prints what would be sent.
library;

import 'dart:io';

import 'package:agenda_core/agenda_core.dart';

Future<void> main(List<String> argv) async {
  final opts = <String, String>{};
  var confirm = false;
  for (var i = 0; i < argv.length; i++) {
    if (argv[i] == '--confirm') {
      confirm = true;
    } else if (argv[i].startsWith('--') && i + 1 < argv.length) {
      opts[argv[i].substring(2)] = argv[++i];
    }
  }
  final to = (opts['to'] ?? '').split(',').where((s) => s.trim().isNotEmpty).toList();
  final cc = (opts['cc'] ?? '').split(',').where((s) => s.trim().isNotEmpty).toList();
  final attach = (opts['attach'] ?? '').split(',').where((s) => s.trim().isNotEmpty).toList();
  for (final a in attach) {
    if (!File(a).existsSync()) {
      stderr.writeln('attachment not found: $a');
      exit(2);
    }
  }
  final subject = opts['subject'] ?? '';
  final bodyFile = opts['body-file'];
  if (to.isEmpty || subject.isEmpty || bodyFile == null) {
    stderr.writeln('usage: send_mail.dart --to a@b --subject "..." --body-file f.txt '
        '[--cc c@d] [--attach a.pdf] [--confirm]');
    exit(2);
  }
  final body = await File(bodyFile).readAsString();
  final settings = await AgendaSettings.load();
  final account = await BridgeAccount.load(settings.paths.accountsDir);
  print('From:    ${account.name == null ? account.address : '${account.name} <${account.address}>'}');
  print('To:      ${to.join(', ')}');
  if (cc.isNotEmpty) print('Cc:      ${cc.join(', ')}');
  print('Subject: $subject');
  for (final a in attach) print('Attach:  $a');
  print('-' * 60);
  print(body.trimRight());
  print('-' * 60);
  if (!confirm) {
    print('dry run, nothing sent (pass --confirm to send)');
    return;
  }
  final response = await BridgeSmtp.send(
    accountsDir: settings.paths.accountsDir,
    to: to,
    cc: cc,
    subject: subject,
    body: body,
    attachments: attach,
    debug: Platform.environment.containsKey('SMTP_DEBUG'),
  );
  print('sent: $response');
}
