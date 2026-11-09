import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// User settings shared by the app and the checker (~/.config/agenda/settings.json).
class AgendaSettings {
  AgendaSettings({
    String? agendaDir,
    this.startAtLogin = true,
    this.backgroundChecks = true,
    this.intervalMinutes = 30,
    this.dailyRunHour = 7,
    this.notifications = true,
    this.model,
    this.runTimeoutMinutes = 20,
    this.calendarSplit = 0.55,
    this.syncEnabled = true,
    String? personalDir,
    this.deviceName,
    this.syncHubs,
  }) : agendaDir = agendaDir ?? AgendaPaths.defaultAgendaDir,
       personalDir = personalDir ?? AgendaPaths.personalDir;

  String agendaDir;
  bool startAtLogin;
  bool backgroundChecks;
  int intervalMinutes;

  /// The first check at or after this hour each day wakes Claude for a full review.
  int dailyRunHour;
  bool notifications;

  /// Claude model alias or id; null uses the Claude Code default.
  String? model;
  int runTimeoutMinutes;

  /// Share of the app window taken by the calendar pane (the task pane gets the rest).
  double calendarSplit;

  /// Sync with the other devices of the account (Reticulum: LAN and public hubs).
  bool syncEnabled;

  /// Reticulum hubs (`host:port`) to connect to; null uses the built-in list.
  List<String>? syncHubs;

  /// The central personal-information folder (~/personal on the desktop).
  String personalDir;

  /// Shown to the other devices; null uses the host name.
  String? deviceName;

  AgendaPaths get paths => AgendaPaths(agendaDir);

  factory AgendaSettings.fromJson(Map<String, Object?> j) => AgendaSettings(
        agendaDir: j['agenda_dir'] as String?,
        startAtLogin: j['start_at_login'] as bool? ?? true,
        backgroundChecks: j['background_checks'] as bool? ?? true,
        intervalMinutes: (j['interval_minutes'] as num?)?.toInt() ?? 30,
        dailyRunHour: (j['daily_run_hour'] as num?)?.toInt() ?? 7,
        notifications: j['notifications'] as bool? ?? true,
        model: (j['model'] as String?)?.trim().isEmpty ?? true ? null : j['model'] as String,
        runTimeoutMinutes: (j['run_timeout_minutes'] as num?)?.toInt() ?? 20,
        calendarSplit: (j['calendar_split'] as num?)?.toDouble() ?? 0.55,
        syncEnabled: j['sync_enabled'] as bool? ?? true,
        personalDir: j['personal_dir'] as String?,
        deviceName: j['device_name'] as String?,
        syncHubs: j['sync_hubs'] is List ? [for (final h in j['sync_hubs'] as List) '$h'] : null,
      );

  Map<String, Object?> toJson() => {
        'agenda_dir': agendaDir,
        'start_at_login': startAtLogin,
        'background_checks': backgroundChecks,
        'interval_minutes': intervalMinutes,
        'daily_run_hour': dailyRunHour,
        'notifications': notifications,
        'model': model,
        'run_timeout_minutes': runTimeoutMinutes,
        'calendar_split': calendarSplit,
        'sync_enabled': syncEnabled,
        'personal_dir': personalDir,
        'device_name': deviceName,
        'sync_hubs': syncHubs,
      };

  /// Keys every device of the account shares, kept in the agenda's
  /// `shared/settings.json` (synced): how the automation behaves.
  static const sharedKeys = {'model', 'daily_run_hour', 'run_timeout_minutes'};

  String get sharedFile => '$agendaDir/shared/settings.json';

  /// The shared values as last read or written, so [save] only touches the ones
  /// changed on this device (a stale device must not undo another's change).
  Map<String, Object?> _sharedSeen = const {};

  Future<Map<String, Object?>?> _readShared() async {
    final f = File(sharedFile);
    if (!await f.exists()) return null;
    try {
      final d = jsonDecode(await f.readAsString());
      return d is Map<String, Object?> ? d : null;
    } on FormatException {
      return null;
    }
  }

  /// Applies the account's shared values (after [agendaDir] is known).
  Future<void> reloadShared() async {
    final d = await _readShared();
    final j = toJson();
    if (d != null) {
      for (final k in sharedKeys) {
        if (d.containsKey(k)) j[k] = d[k];
      }
    }
    final s = AgendaSettings.fromJson(j);
    model = s.model;
    dailyRunHour = s.dailyRunHour;
    runTimeoutMinutes = s.runTimeoutMinutes;
    _sharedSeen = {for (final k in sharedKeys) k: j[k]};
  }

  /// Loads this device's settings and overlays the account's shared ones.
  static Future<AgendaSettings> load({String? file}) async {
    final f = File(file ?? AgendaPaths.settingsFile);
    var s = AgendaSettings();
    if (await f.exists()) {
      try {
        final d = jsonDecode(await f.readAsString());
        if (d is Map<String, Object?>) s = AgendaSettings.fromJson(d);
      } on FormatException {
        // defaults
      }
    }
    await s.reloadShared();
    return s;
  }

  /// Saves this device's settings, and the shared values changed on this device.
  Future<void> save({String? file}) async {
    final j = toJson();
    await writeAtomic(file ?? AgendaPaths.settingsFile, const JsonEncoder.withIndent('  ').convert(j));
    final current = await _readShared();
    final changed = {
      for (final k in sharedKeys)
        if (current == null || j[k] != _sharedSeen[k]) k: j[k],
    };
    if (changed.isEmpty) return;
    final out = {'version': 1, ...?current, ...changed};
    if (current != null && changed.keys.every((k) => current[k] == changed[k])) return;
    await writeAtomic(sharedFile, '${const JsonEncoder.withIndent('  ').convert(out)}\n');
    _sharedSeen = {for (final k in sharedKeys) k: out[k]};
  }
}
