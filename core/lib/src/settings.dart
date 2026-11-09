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

  /// Desktop: serve the agenda and ~/personal to paired phones on the LAN.
  bool syncEnabled;

  /// The central personal-information folder (~/personal on the desktop).
  String personalDir;

  /// Shown to the other device when pairing; null uses the host name.
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
      };

  static Future<AgendaSettings> load() async {
    final file = File(AgendaPaths.settingsFile);
    if (!await file.exists()) return AgendaSettings();
    try {
      final j = jsonDecode(await file.readAsString());
      return j is Map<String, Object?> ? AgendaSettings.fromJson(j) : AgendaSettings();
    } on FormatException {
      return AgendaSettings();
    }
  }

  Future<void> save() => writeAtomic(
        AgendaPaths.settingsFile,
        const JsonEncoder.withIndent('  ').convert(toJson()),
      );
}
