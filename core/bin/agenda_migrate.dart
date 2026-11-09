/// Migrates the old tasks.json layout to projects/<id>/ (see docs/format.md).
///
///   dart run core/bin/agenda_migrate.dart --dry-run          plan only, prints moves and ids
///   dart run core/bin/agenda_migrate.dart                    apply
///   dart run core/bin/agenda_migrate.dart --validate         load the new layout, report problems
///   options: --agenda-dir DIR (default: settings), --seed N (deterministic uids)
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agenda_core/agenda_core.dart';

Future<void> main(List<String> argv) async {
  final opts = <String, String>{};
  final flags = <String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--dry-run' || a == '--validate' || a == '--help') {
      flags.add(a);
    } else if (a.startsWith('--') && i + 1 < argv.length) {
      opts[a.substring(2)] = argv[++i];
    } else {
      stderr.writeln('unknown argument $a');
      exit(2);
    }
  }
  if (flags.contains('--help')) {
    print('usage: agenda_migrate [--dry-run | --validate] [--agenda-dir DIR] [--seed N]');
    return;
  }
  final agendaDir = opts['agenda-dir'] ?? (await AgendaSettings.load()).agendaDir;

  if (flags.contains('--validate')) {
    exit(await validate(agendaDir));
  }
  try {
    await migrateLegacy(
      agendaDir: agendaDir,
      dryRun: flags.contains('--dry-run'),
      rng: opts['seed'] == null ? null : Random(int.parse(opts['seed']!)),
      log: print,
    );
  } on StateError catch (e) {
    stderr.writeln('cannot migrate: ${e.message}');
    exit(1);
  }
}

Future<int> validate(String agendaDir) async {
  final agenda = await loadAgenda(agendaDir);
  var problems = 0;
  for (final e in agenda.errors) {
    print('error: $e');
    problems++;
  }
  for (final p in agenda.projects) {
    final pj = jsonDecode(await File(p.jsonPath).readAsString()) as Map<String, Object?>;
    for (final m in validateProjectJson(pj)) {
      print('${p.jsonPath}: $m');
      problems++;
    }
    for (final t in p.tasks) {
      final tj = jsonDecode(await File(t.jsonPath).readAsString()) as Map<String, Object?>;
      for (final m in validateTaskJson(tj)) {
        print('${t.jsonPath}: $m');
        problems++;
      }
    }
  }
  print('${agenda.projects.length} projects, ${agenda.allTasks.length} tasks, '
      '${agenda.needsUser.length} need you, ${agenda.watchedSenders.length} watched senders, '
      '${agenda.events.length} events, ${agenda.upcoming().length} upcoming dates; $problems problems');
  return problems == 0 ? 0 : 1;
}
