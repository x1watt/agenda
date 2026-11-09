import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'claude_process.dart';
import 'mail.dart';
import 'paths.dart';
import 'settings.dart';
import 'model.dart';
import 'store.dart';

/// Checker memory between ticks. The part every device shares (the last full run,
/// mail already reported, deadlines already announced) lives in the agenda's
/// `shared/checker-state.json` and syncs; the boot id and the last check of this
/// device stay in ~/.local/state/agenda/state.json.
class CheckState {
  CheckState({
    this.bootId,
    this.lastCheck,
    this.lastFullRun,
    Set<String>? seen,
    Set<String>? notifiedDeadlines,
  })  : seen = seen ?? {},
        notifiedDeadlines = notifiedDeadlines ?? {};

  String? bootId;
  DateTime? lastCheck;
  DateTime? lastFullRun;

  /// Mail already reported to Claude, as `FOLDER:UID`.
  final Set<String> seen;

  /// Deadlines already announced as entering the 24 h window.
  final Set<String> notifiedDeadlines;

  factory CheckState.fromJson(Map<String, Object?> j) => CheckState(
        bootId: j['boot_id'] as String?,
        lastCheck: DateTime.tryParse('${j['last_check'] ?? ''}'),
        lastFullRun: DateTime.tryParse('${j['last_full_run'] ?? ''}'),
        seen: {if (j['seen'] case final List<Object?> l) for (final x in l) '$x'},
        notifiedDeadlines: {
          if (j['notified_deadlines'] case final List<Object?> l) for (final x in l) '$x'
        },
      );

  Map<String, Object?> toJson() => {..._localJson(), ..._sharedJson()};

  Map<String, Object?> _localJson() => {
        'boot_id': bootId,
        'last_check': lastCheck?.toIso8601String(),
      };

  Map<String, Object?> _sharedJson() {
    final seenList = seen.toList();
    return {
      'last_full_run': lastFullRun?.toIso8601String(),
      'seen': seenList.length > 2000 ? seenList.sublist(seenList.length - 2000) : seenList,
      'notified_deadlines': notifiedDeadlines.toList(),
    };
  }

  static Future<Map<String, Object?>?> _read(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString());
      return j is Map<String, Object?> ? j : null;
    } on FormatException {
      return null;
    }
  }

  /// Loads this device's part and, from [sharedFile], the account's part. Before the
  /// shared file exists, the old single file provides both.
  static Future<CheckState> load({String? sharedFile, String? localFile}) async {
    final local = await _read(localFile ?? AgendaPaths.stateFile) ?? const {};
    final shared = sharedFile == null ? null : await _read(sharedFile);
    return CheckState.fromJson({...local, if (shared != null) ...{
      'last_full_run': shared['last_full_run'],
      'seen': shared['seen'],
      'notified_deadlines': shared['notified_deadlines'],
    }});
  }

  Future<void> save({String? sharedFile, String? localFile}) async {
    if (sharedFile == null) {
      await writeAtomic(localFile ?? AgendaPaths.stateFile, const JsonEncoder.withIndent('  ').convert(toJson()));
      return;
    }
    await writeAtomic(localFile ?? AgendaPaths.stateFile, const JsonEncoder.withIndent('  ').convert(_localJson()));
    await writeAtomic(sharedFile, encodeJson({'version': 1, ..._sharedJson()}));
  }
}

/// Id of this installation: random, made once, kept in ~/.config/agenda/device-id.
Future<String> localDeviceId({String? file}) async {
  final f = File(file ?? AgendaPaths.deviceIdFile);
  if (await f.exists()) {
    final s = (await f.readAsString()).trim();
    if (s.length >= 8) return s;
  }
  final r = Random.secure();
  final id = [for (var i = 0; i < 8; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  await writeAtomic(f.path, '$id\n');
  return id;
}

/// Who runs the background checks: one device of the account at a time. The
/// holder renews its lease every tick; another device takes over only once the
/// lease ran out (the holder is off or stopped checking). The file syncs, so two
/// devices that took a free lease at the same moment converge on one holder at
/// the next sync (the newer write wins) and the other steps back.
class CheckerLock {
  CheckerLock({required this.device, required this.name, required this.until});

  final String device;
  final String name;
  final DateTime until;

  factory CheckerLock.fromJson(Map<String, Object?> j) => CheckerLock(
        device: '${j['device'] ?? ''}',
        name: '${j['name'] ?? ''}',
        until: DateTime.tryParse('${j['until'] ?? ''}') ?? DateTime(0),
      );

  Map<String, Object?> toJson() => {'version': 1, 'device': device, 'name': name, 'until': until.toIso8601String()};

  /// Takes or renews the lease in [path] for [device]. Returns null when this device
  /// now holds it, or the lock of the other device that does.
  static Future<CheckerLock?> take(String path, {required String device, required String name, required Duration lease, required DateTime now}) async {
    final f = File(path);
    if (await f.exists()) {
      try {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, Object?>) {
          final held = CheckerLock.fromJson(j);
          if (held.device != device && held.until.isAfter(now)) return held;
        }
      } on FormatException {
        // A broken lock is a free lock.
      }
    }
    await writeAtomic(path, encodeJson(CheckerLock(device: device, name: name, until: now.add(lease)).toJson()));
    return null;
  }
}

String deadlineKey(Deadline d) => '${d.date}|${d.project}|${d.task}|${d.text}';

/// Deadlines within the next 24 h (today or tomorrow) not yet announced.
List<Deadline> deadlinesEnteringWindow(Agenda? agenda, CheckState state, DateTime now) {
  if (agenda == null) return const [];
  final today = DateTime(now.year, now.month, now.day);
  return [
    for (final d in agenda.upcoming(from: now))
      if (d.when != null &&
          d.when!.difference(today).inDays <= 1 &&
          !state.notifiedDeadlines.contains(deadlineKey(d)))
        d,
  ];
}

/// Why Claude should be woken this tick; empty means no full run.
List<String> decideReasons({
  required DateTime now,
  required CheckState state,
  required String? bootId,
  required bool runNow,
  required List<MailHeader> newMail,
  required List<Deadline> deadlines,
  required int dailyRunHour,
}) {
  final reasons = <String>[];
  if (runNow) reasons.add('manual run');
  if (bootId != null && state.bootId != bootId) reasons.add('first check after boot');
  final dailyAt = DateTime(now.year, now.month, now.day, dailyRunHour);
  if (!now.isBefore(dailyAt) && (state.lastFullRun == null || state.lastFullRun!.isBefore(dailyAt))) {
    reasons.add('daily review');
  }
  for (final m in newMail) {
    reasons.add('new mail: ${m.from}, "${m.subject}"');
  }
  for (final d in deadlines) {
    reasons.add('deadline ${d.date}: ${d.text}');
  }
  return reasons;
}

/// Record of one background run (agenda/runs/<id>.json).
class RunRecord {
  RunRecord({
    required this.id,
    required this.reasons,
    required this.started,
    this.ended,
    this.exitCode,
    this.sessionId,
    this.summary,
    this.costUsd,
    this.timedOut = false,
    this.error,
  });

  final String id;
  final List<String> reasons;
  final DateTime started;
  DateTime? ended;
  int? exitCode;
  String? sessionId;
  String? summary;
  double? costUsd;
  bool timedOut;
  String? error;

  bool get ok => error == null && !timedOut && exitCode == 0;

  factory RunRecord.fromJson(Map<String, Object?> j) => RunRecord(
        id: '${j['id'] ?? ''}',
        reasons: [if (j['trigger'] case final List<Object?> l) for (final x in l) '$x'],
        started: DateTime.tryParse('${j['started'] ?? ''}') ?? DateTime(0),
        ended: DateTime.tryParse('${j['ended'] ?? ''}'),
        exitCode: (j['exit_code'] as num?)?.toInt(),
        sessionId: j['session_id'] as String?,
        summary: j['summary'] as String?,
        costUsd: (j['cost_usd'] as num?)?.toDouble(),
        timedOut: j['timed_out'] == true,
        error: j['error'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'trigger': reasons,
        'started': started.toIso8601String(),
        'ended': ended?.toIso8601String(),
        'exit_code': exitCode,
        'session_id': sessionId,
        'summary': summary,
        'cost_usd': costUsd,
        'timed_out': timedOut,
        'error': error,
      };

  Future<void> save(String runsDir) =>
      writeAtomic('$runsDir/$id.json', const JsonEncoder.withIndent('  ').convert(toJson()));
}

/// Run records, newest first.
Future<List<RunRecord>> listRuns(String runsDir, {int limit = 200}) async {
  final dir = Directory(runsDir);
  if (!await dir.exists()) return const [];
  final files = [
    await for (final f in dir.list())
      if (f is File && f.path.endsWith('.json')) f,
  ]..sort((a, b) => b.path.compareTo(a.path));
  final out = <RunRecord>[];
  for (final f in files.take(limit)) {
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is Map<String, Object?>) out.add(RunRecord.fromJson(j));
    } on FormatException {
      continue;
    }
  }
  return out;
}

String runIdFor(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

Future<String?> readBootId() async {
  try {
    return (await File('/proc/sys/kernel/random/boot_id').readAsString()).trim();
  } on FileSystemException {
    return null;
  }
}

/// True when the app holds the chat lock (a chat turn is streaming).
Future<bool> chatActive() async {
  final f = File(AgendaPaths.chatLock);
  if (!await f.exists()) return false;
  final raf = await f.open(mode: FileMode.append);
  try {
    await raf.lock(FileLock.exclusive);
    await raf.unlock();
    return false;
  } on FileSystemException {
    return true;
  } finally {
    await raf.close();
  }
}

/// One checker tick. Returns the process exit code.
Future<int> runCheck({bool force = false, bool dryRun = false, void Function(String)? log}) async {
  void say(String s) => (log ?? print)(s);
  await Directory(AgendaPaths.cacheDir).create(recursive: true);

  final lockFile = await File(AgendaPaths.checkLock).open(mode: FileMode.append);
  try {
    await lockFile.lock(FileLock.exclusive);
  } on FileSystemException {
    say('another check is running; skipping');
    await lockFile.close();
    return 0;
  }

  try {
    final settings = await AgendaSettings.load();
    final paths = settings.paths;
    final runNowFile = File(AgendaPaths.runNowFlag);
    final runNow = force || await runNowFile.exists();
    if (!settings.backgroundChecks && !runNow) {
      say('background checks disabled');
      return 0;
    }

    final now = DateTime.now();

    // One device of the account runs the checks; "Run now" runs here regardless.
    if (!runNow) {
      final lease = Duration(minutes: 2 * settings.intervalMinutes + 5);
      final held = await CheckerLock.take(paths.checkerLockFile,
          device: await localDeviceId(), name: settings.deviceName ?? Platform.localHostname, lease: lease, now: now);
      if (held != null) {
        say('checks run on ${held.name} (lease until ${held.until.toIso8601String().substring(0, 16)}); skipping');
        return 0;
      }
    }

    final state = await CheckState.load(sharedFile: paths.checkerStateFile);
    final bootId = await readBootId();

    Agenda? agenda;
    try {
      agenda = await loadAgenda(paths.agendaDir);
      for (final e in agenda.errors) {
        say('agenda: $e');
      }
    } on Object catch (e) {
      say('agenda unreadable: $e');
    }

    // Watched mail since the last check (IMAP SINCE is per day, so look back a bit).
    final newMail = <MailHeader>[];
    final newKeys = <String>[];
    final senders = agenda?.watchedSenders ?? const <String>[];
    if (senders.isNotEmpty) {
      if (await BridgeMail.reachable()) {
        final since = (state.lastCheck ?? now).subtract(const Duration(days: 2));
        BridgeMail? mail;
        try {
          mail = await BridgeMail.connect(paths.accountsDir);
          await mail.open('INBOX');
          final uids = await mail.search('${fromAnyCriteria(senders)} SINCE ${imapDate(since)}');
          final fresh = uids.where((u) => !state.seen.contains('INBOX:$u')).toList();
          newMail.addAll(await mail.headers(fresh));
          newKeys.addAll(fresh.map((u) => 'INBOX:$u'));
        } on Object catch (e) {
          say('mail check failed: $e');
        } finally {
          await mail?.close();
        }
      } else {
        say('Bridge not reachable; mail check skipped');
      }
    }

    final deadlines = deadlinesEnteringWindow(agenda, state, now);
    final reasons = decideReasons(
      now: now,
      state: state,
      bootId: bootId,
      runNow: runNow,
      newMail: newMail,
      deadlines: deadlines,
      dailyRunHour: settings.dailyRunHour,
    );

    say('watched senders: ${senders.length}, new mail: ${newMail.length}, '
        'deadlines: ${deadlines.length}');
    if (reasons.isEmpty) {
      say('nothing to do');
      if (!dryRun) {
        state.lastCheck = now;
        await state.save(sharedFile: paths.checkerStateFile);
      }
      return 0;
    }
    say('reasons: ${reasons.join('; ')}');
    if (dryRun) return 0;

    if (await chatActive()) {
      // Leave mail unseen and the flag in place so the next tick picks them up.
      say('chat in progress; deferring the full run');
      state.lastCheck = now;
      await state.save(sharedFile: paths.checkerStateFile);
      return 0;
    }

    if (await runNowFile.exists()) await runNowFile.delete();
    final record = RunRecord(id: runIdFor(now), reasons: reasons, started: now);
    await record.save(paths.runsDir);
    final prompt = await _buildPrompt(paths, reasons, newMail);

    try {
      final outcome = await runClaudeOnce(
        cwd: paths.agendaDir,
        prompt: prompt,
        model: settings.model,
        timeout: Duration(minutes: settings.runTimeoutMinutes),
        onEvent: (e) {
          if (e is ToolUseEvent) say('  ${e.summary}');
        },
      );
      record
        ..exitCode = outcome.exitCode
        ..sessionId = outcome.sessionId
        ..summary = outcome.result?.text
        ..costUsd = outcome.result?.costUsd
        ..timedOut = outcome.timedOut;
      if (outcome.result?.isError ?? true) record.error = 'run did not finish cleanly';
    } on ProcessException catch (e) {
      record.error = 'cannot start claude: ${e.message}';
    }
    record.ended = DateTime.now();
    await record.save(paths.runsDir);
    say('run ${record.id} finished: exit ${record.exitCode}, ${record.error ?? 'ok'}');

    state
      ..bootId = bootId ?? state.bootId
      ..lastCheck = now
      ..lastFullRun = now
      ..seen.addAll(newKeys)
      ..notifiedDeadlines.addAll(deadlines.map(deadlineKey));
    await state.save(sharedFile: paths.checkerStateFile);

    if (settings.notifications) {
      var needsUser = 0;
      try {
        needsUser = (await loadAgenda(paths.agendaDir)).needsUser.length;
      } on Object {
        // keep 0
      }
      if (runNow || needsUser > 0 || newMail.isNotEmpty || !record.ok) {
        await _notify(record, needsUser);
      }
    }
    return 0;
  } finally {
    await lockFile.unlock();
    await lockFile.close();
  }
}

Future<String> _buildPrompt(AgendaPaths paths, List<String> reasons, List<MailHeader> mail) async {
  var base = 'Review the agenda: read every projects/*/project.json and task.json, check for '
      'replies, update the files, and end with a short summary.';
  try {
    base = await File(paths.reviewPrompt).readAsString();
  } on FileSystemException {
    // fall back to the short default
  }
  final b = StringBuffer(base.trim())
    ..writeln()
    ..writeln()
    ..writeln('## This run')
    ..writeln('Now: ${DateTime.now().toIso8601String()}')
    ..writeln('Triggered by: ${reasons.join('; ')}');
  if (mail.isNotEmpty) {
    b.writeln('New mail from watched senders (INBOX UIDs, read them with the mail tool):');
    for (final m in mail) {
      b.writeln('- UID ${m.uid}, ${m.date?.toIso8601String() ?? '?'}, ${m.from}: ${m.subject}');
    }
  }
  return b.toString();
}

Future<void> _notify(RunRecord r, int needsUser) async {
  final firstLines = (r.summary ?? r.error ?? 'Run finished')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .take(3)
      .join('\n');
  final body = firstLines.length > 300 ? '${firstLines.substring(0, 300)}...' : firstLines;
  final title = needsUser > 0 ? 'agenda: $needsUser need you' : 'agenda';
  final icon = '${AgendaPaths.installDir}/icon.png';
  try {
    await Process.run('notify-send', [
      '-a', 'agenda', //
      if (File(icon).existsSync()) ...['-i', icon],
      title,
      body,
    ]);
  } on ProcessException {
    // no notification daemon; the run record is still there
  }
}
