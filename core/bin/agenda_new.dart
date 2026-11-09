/// Creates projects and tasks with valid ids and folders (see docs/format.md).
///
///   agenda-new project --id car --title "Car"
///   agenda-new task --project car --name "Renew the insurance"
///                   [--status todo] [--priority 3] [--due YYYY-MM-DD] [--next "first step"]
///   options: --agenda-dir DIR (default: settings)
///
/// Prints the created folder. Installed compiled as `agenda-new`.
library;

import 'dart:io';

import 'package:agenda_core/agenda_core.dart';

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
  final cmd = positional.firstOrNull;
  if (cmd != 'project' && cmd != 'task') {
    stderr.writeln('usage: agenda-new project --id ID --title T | task --project ID --name N [--status S] [--priority P] [--due D] [--next TEXT]');
    exit(2);
  }
  final agendaDir = opts['agenda-dir'] ?? (await AgendaSettings.load()).agendaDir;
  try {
    if (cmd == 'project') {
      final id = opts['id'];
      final title = opts['title'] ?? id;
      if (id == null) throw ArgumentError('--id is required');
      final p = await createProject(agendaDir: agendaDir, id: id, title: title!);
      print(p.dir);
    } else {
      final pid = opts['project'];
      final name = opts['name'];
      if (pid == null || name == null) throw ArgumentError('--project and --name are required');
      final agenda = await loadAgenda(agendaDir);
      final p = agenda.projectById(pid);
      if (p == null) throw ArgumentError('no project "$pid" (have: ${agenda.projects.map((p) => p.id).join(', ')})');
      final status = TaskStatus.values.where((s) => s.id == (opts['status'] ?? 'todo')).firstOrNull;
      if (status == null) throw ArgumentError('status must be one of ${TaskStatus.values.map((s) => s.id).join(', ')}');
      final due = opts['due'];
      if (due != null && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(due)) throw ArgumentError('--due must be YYYY-MM-DD');
      final t = await createTask(
        project: p,
        name: name,
        status: status,
        priority: int.tryParse(opts['priority'] ?? '') ?? 3,
        due: due,
        nextStep: opts['next'],
      );
      print(t.dir);
    }
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    exit(2);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}
