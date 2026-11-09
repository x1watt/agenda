/// Background checker, run by the `agenda-check` systemd user timer.
///
/// Each tick is cheap: it looks for mail from watched senders and deadlines
/// entering the next 24 hours. Claude is woken for a full review only on the
/// first check after a boot, the daily review, new watched mail, a deadline,
/// or a "Run now" request.
///
///   agenda_check            one tick
///   agenda_check --force    full run now
///   agenda_check --dry-run  show what would happen, change nothing
library;

import 'dart:io';

import 'package:agenda_core/agenda_core.dart';

Future<void> main(List<String> args) async {
  final code = await runCheck(
    force: args.contains('--force'),
    dryRun: args.contains('--dry-run'),
    log: (s) => stdout.writeln('${DateTime.now().toIso8601String().substring(0, 19)} $s'),
  );
  exit(code);
}
