/// Read-only mailbox reader over the local Proton Mail Bridge.
///
/// Usage (from agenda/):
///   dart run core/bin/protonmail.dart folders
///   dart run core/bin/protonmail.dart recent [N] [--folder INBOX]
///   dart run core/bin/protonmail.dart search [--from X] [--subject X] [--text X]
///       [--since DD.MM.YYYY] [--folder INBOX]
///   dart run core/bin/protonmail.dart show UID [--folder INBOX]
///   dart run core/bin/protonmail.dart save UID DIR [--folder INBOX]   (writes the attachments)
///   dart run core/bin/protonmail.dart watched [--since DD.MM.YYYY]   (all watch senders, default 7 days)
///
/// Installed compiled as `agenda-mail` (same arguments), which starts much faster.
///
/// Set IMAP_DEBUG=1 to print the protocol exchange.
library;

import 'dart:io';

import 'package:agenda_core/agenda_core.dart';

String two(int n) => n.toString().padLeft(2, '0');

String fmt(DateTime? d) => d == null
    ? '?'.padRight(16)
    : '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';

String cut(String s, int n) => s.length > n ? s.substring(0, n) : s.padRight(n);

void printHeaders(List<MailHeader> rows, {int limit = 50}) {
  if (rows.isEmpty) {
    print('(no messages)');
    return;
  }
  for (final r in rows.take(limit)) {
    print('${r.uid.toString().padLeft(7)}  ${fmt(r.date)}  ${cut(r.from, 40)}  ${r.subject}');
  }
}

Future<void> main(List<String> argv) async {
  final positional = <String>[];
  final opts = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--') && i + 1 < argv.length) {
      opts[argv[i].substring(2)] = argv[++i];
    } else {
      positional.add(argv[i]);
    }
  }
  const commands = ['folders', 'recent', 'search', 'show', 'save', 'watched'];
  if (positional.isEmpty || !commands.contains(positional.first)) {
    stderr.writeln('usage: protonmail.dart ${commands.join('|')} [args] (see file header)');
    exit(2);
  }
  final cmd = positional.first;
  final arg = positional.length > 1 ? positional[1] : null;
  final folder = opts['folder'] ?? 'INBOX';

  final settings = await AgendaSettings.load();
  final mail = await BridgeMail.connect(settings.paths.accountsDir,
      debug: Platform.environment.containsKey('IMAP_DEBUG'));
  try {
    switch (cmd) {
      case 'folders':
        (await mail.folders()).forEach(print);
      case 'recent':
        // Last N messages by date, looking back at most 30 days.
        await mail.open(folder);
        final since = DateTime.now().subtract(const Duration(days: 30));
        printHeaders(await mail.headers(await mail.search('SINCE ${imapDate(since)}')),
            limit: int.tryParse(arg ?? '') ?? 20);
      case 'search':
        await mail.open(folder);
        final crit = <String>[
          if (opts['from'] != null) 'FROM ${imapQuote(opts['from']!)}',
          if (opts['subject'] != null) 'SUBJECT ${imapQuote(opts['subject']!)}',
          if (opts['text'] != null) 'TEXT ${imapQuote(opts['text']!)}',
          if (opts['since'] case final s?) 'SINCE ${imapDate(_parseDmy(s))}',
        ];
        printHeaders(await mail.headers(await mail.search(crit.isEmpty ? 'ALL' : crit.join(' '))));
      case 'watched':
        // Mail from every sender watched by an open task.
        final agenda = await loadAgenda(settings.paths.agendaDir);
        final since = opts['since'] == null
            ? DateTime.now().subtract(const Duration(days: 7))
            : _parseDmy(opts['since']!);
        await mail.open(folder);
        final senders = agenda.watchedSenders;
        print('watched: ${senders.join(', ')}');
        if (senders.isEmpty) break;
        printHeaders(await mail.headers(
            await mail.search('${fromAnyCriteria(senders)} SINCE ${imapDate(since)}')));
      case 'save':
        // save UID DIR: write the message's attachments into DIR.
        final suid = int.tryParse(arg ?? '');
        final dir = positional.length > 2 ? positional[2] : null;
        if (suid == null || dir == null) {
          stderr.writeln('save needs a UID and a directory');
          exit(2);
        }
        await mail.open(folder);
        (await mail.saveAttachments(suid, dir)).forEach(print);
      case 'show':
        final uid = int.tryParse(arg ?? '');
        if (uid == null) {
          stderr.writeln('show needs a UID');
          exit(2);
        }
        await mail.open(folder);
        final m = await mail.message(uid);
        if (m == null) {
          stderr.writeln('no message with UID $uid in $folder');
          exit(1);
        }
        print('From: ${m.from}');
        print('To: ${m.to}');
        print('Date: ${fmt(m.date)}');
        print('Subject: ${m.subject}');
        if (m.attachments.isNotEmpty) print('Attachments: ${m.attachments.join(', ')}');
        print('');
        print(m.body);
    }
  } finally {
    await mail.close();
  }
  // enough_mail keeps a socket listener alive after LOGOUT, which would keep
  // the VM running.
  exit(0);
}

DateTime _parseDmy(String s) {
  final p = s.split('.');
  return DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
}
