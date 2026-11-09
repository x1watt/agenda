import 'dart:convert';
import 'dart:io';

const _enc = JsonEncoder.withIndent('  ');

Future<void> _json(String path, Map<String, Object?> j) async {
  await File(path).parent.create(recursive: true);
  await File(path).writeAsString('${_enc.convert(j)}\n');
}

/// A small agenda with two projects and three tasks. Returns the agenda dir.
Future<String> writeFixtureAgenda(Directory tmp) async {
  final dir = '${tmp.path}/agenda';
  final car = '$dir/projects/car';
  final health = '$dir/projects/house';
  await _json('$car/project.json', {
    'version': 1,
    'id': 'car',
    'title': 'Car',
    'created': '2026-09-10T00:00:00',
    'status': 'quotes pending',
    'docs': ['data/TASKS.md'],
    'deadlines': [
      {'date': '2026-12-31', 'text': 'Change insurer', 'task': 'AB2-CD3'},
      {'date': '2026-01-01', 'text': 'past', 'task': null},
    ],
    'conversation': [],
    'threads': [],
  });
  await Directory('$car/sources').create(recursive: true);
  await File('$car/data/TASKS.md').create(recursive: true);
  await File('$car/data/TASKS.md').writeAsString('# Tasks\n');
  await _json('$car/AB2-CD3-insurance/task.json', {
    'version': 1,
    'uid': 'AB2-CD3',
    'name': 'Insurance',
    'status': 'todo',
    'priority': 1,
    'created': '2026-09-10T00:00:00',
    'due': '2026-09-18',
    'scheduled': '2026-09-16T14:30',
    'next_step': 'Fill the forms using guide.md',
    'waiting_on': null,
    'watch': [
      {'from': 'Insurer'},
    ],
    'items': [
      {'id': '1', 'text': 'Request the mileage', 'done': false, 'done_at': null, 'due': null},
      {'id': '2', 'text': 'Download forms', 'done': true, 'done_at': '2026-09-11T12:00:00', 'due': null},
    ],
    'history': [
      {'date': '2026-09-11', 'text': 'Policy quoted'},
    ],
    'files': [
      {'path': 'guide.md', 'status': 'needs_review', 'at': '2026-09-14T09:00:00'},
    ],
    'conversation': [
      {'at': '2026-09-12T10:00:00', 'role': 'user', 'text': 'Is the policy cancelled?', 'session': 'old-session'},
      {'at': '2026-09-12T10:00:10', 'role': 'assistant', 'text': 'Not yet, the form needs a signature.', 'session': 'old-session'},
    ],
    'threads': [
      {'id': 'old-session', 'created': '2026-09-12T10:00:00', 'archived': true, 'archived_at': '2026-09-12T11:00:00', 'archived_reason': 'done'},
    ],
    'legacy_id': 'T1',
    'extra_field': 'kept',
  });
  await File('$car/AB2-CD3-insurance/guide.md').writeAsString('# Guide\n');
  await _json('$car/XY7-Q8W-letter/task.json', {
    'version': 1,
    'uid': 'XY7-Q8W',
    'name': 'Letter',
    'status': 'done',
    'priority': 3,
    'created': '2026-09-09T00:00:00',
    'due': null,
    'next_step': null,
    'waiting_on': null,
    'watch': [
      {'from': 'old@x'},
    ],
    'items': [],
    'history': [
      {'date': '2026-09-11', 'text': 'Posted'},
    ],
    'files': [],
    'conversation': [],
    'threads': [],
  });
  await _json('$health/project.json', {
    'version': 1,
    'id': 'house',
    'title': 'House',
    'created': '2026-09-09T00:00:00',
    'status': 'no appointment yet',
    'docs': [],
    'deadlines': [],
    'conversation': [],
    'threads': [],
  });
  await _json('$health/NPR-5TG-roof-check/task.json', {
    'version': 1,
    'uid': 'NPR-5TG',
    'name': 'Roof check',
    'status': 'needs_user',
    'priority': 1,
    'created': '2026-09-09T00:00:00',
    'due': '2026-09-12',
    'next_step': 'Call the practice',
    'waiting_on': null,
    'watch': [
      {'from': 'roofer.example'},
    ],
    'items': [],
    'history': [],
    'files': [],
    'conversation': [],
    'threads': [
      {'id': 'live-session', 'created': '2026-09-11T17:59:00', 'archived': false, 'archived_at': null, 'archived_reason': null},
    ],
  });
  await _json('$dir/general.json', {'version': 1, 'conversation': [], 'threads': []});
  await _json('$dir/events.json', {
    'version': 1,
    'events': [
      {'id': 'e1', 'date': '2026-09-17', 'time': '09:00', 'end': null, 'title': 'Dentist', 'note': null, 'task': 'NPR-5TG', 'project': 'house'},
    ],
  });
  await Directory('$dir/runs').create(recursive: true);
  return dir;
}

/// The old layout: agenda/tasks.json + threads.json + next.md and sibling
/// project folders with content. Returns the agenda dir.
Future<String> writeLegacyWorkspace(Directory tmp) async {
  final ws = tmp.path;
  final dir = '$ws/agenda';
  await _json('$dir/tasks.json', {
    'version': 1,
    'updated': '2026-09-11T15:30:00+02:00',
    'projects': [
      {
        'id': 'car',
        'title': 'Car',
        'folder': '../car',
        'docs': ['../car/TASKS.md', '../car/PLAN.md'],
        'status': 'quotes pending',
        'tasks': [
          {
            'id': 'T1',
            'title': 'Insurance',
            'status': 'todo',
            'priority': 1,
            'due': '2026-09-18',
            'next_step': 'Fill insurance/form-help.md',
            'watch': [
              {'from': 'Insurer'},
            ],
            'history': [
              {'date': '2026-09-11', 'text': 'Policy quoted'},
            ],
            'files': [
              {'path': '../car/insurance/form-help.md', 'status': 'needs_review', 'at': '2026-09-14T09:00:00'},
            ],
          },
          {
            'id': 'T19-23',
            'title': 'Letter to the dealer',
            'status': 'done',
            'watch': [
              {'from': 'old@x'},
            ],
          },
        ],
      },
      {
        'id': 'health',
        'title': 'Home',
        'folder': '../house',
        'docs': ['../house/repairs.md'],
        'tasks': [
          {
            'id': 'H1',
            'title': 'Roof check',
            'status': 'needs_user',
            'due': '2026-09-12',
            'watch': [
              {'from': 'roofer.example'},
            ],
            'files': [
              {'path': '../house/reply-roofer.md', 'status': 'needs_review', 'at': '2026-09-14T10:00:00'},
            ],
          },
        ],
      },
    ],
    'deadlines': [
      {'date': '2026-12-31', 'text': 'Change insurer', 'project': 'car', 'task': 'T1'},
      {'date': '2026-12-19', 'text': 'Quote expires', 'project': 'car'},
      {'date': '2026-10-25', 'text': 'Warranty ends', 'project': 'car', 'task': 'T99'},
      {'date': '2026-01-01', 'text': 'no project'},
    ],
  });
  await _json('$dir/threads.json', {
    'version': 1,
    'threads': [
      {'id': 's-h1', 'node': 'task:health/H1', 'created': '2026-09-11T17:59:11', 'archived': false, 'archived_at': null, 'archived_reason': null},
      {'id': 's-t2', 'node': 'task:car/T2', 'created': '2026-09-11T18:30:43', 'archived': true, 'archived_at': '2026-09-11T18:37:55', 'archived_reason': 'T2 sent'},
      {'id': 's-p', 'node': 'project:car', 'created': '2026-09-11T19:00:00', 'archived': false, 'archived_at': null, 'archived_reason': null},
      {'id': 's-g', 'node': 'general', 'created': '2026-09-11T19:30:00', 'archived': false, 'archived_at': null, 'archived_reason': null},
    ],
  });
  await File('$dir/next.md').writeAsString('# Next\n');
  await File('$dir/CLAUDE.md').writeAsString('# Agenda\n');

  Future<void> w(String path, String text) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(text);
  }

  await w('$ws/car/TASKS.md', '# Tasks\nSee [plan](PLAN.md), [INS](insurance/INSURANCE.md), forms in insurance/forms/ and [next](../agenda/next.md).\n');
  await w('$ws/car/PLAN.md', '# Plan\nInvoices in invoices/.\n');
  await w('$ws/car/insurance/INSURANCE.md', '# INS\nGuide: [guide](form-help.md). Forms: forms/FORM1.pdf. Plan: [plan](../PLAN.md).\n');
  await w('$ws/car/insurance/form-help.md', '# Guide\nBack to [INS](INSURANCE.md), forms in forms/.\n');
  await w('$ws/car/insurance/forms/FORM1.pdf', 'pdf');
  await Directory('$ws/car/insurance/receipts').create(recursive: true);
  await w('$ws/car/invoices/Invoice 2021.pdf', 'pdf');
  await w('$ws/car/post/letter.pdf', 'pdf');
  await w('$ws/house/repairs.md', '# Home\nReply: [antwort](reply-roofer.md), request [email](email.md).\n');
  await w('$ws/house/reply-roofer.md', '# Antwort\n');
  await w('$ws/house/email.md', '# Email\n');
  return dir;
}
