import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:agenda_core/agenda_core.dart';

/// Desktop and systemd plumbing behind the Settings page.
class SystemIntegration {
  static const timer = 'agenda-check.timer';
  static const service = 'agenda-check.service';

  static String get installedBinary => '${AgendaPaths.installDir}/agenda';

  /// What starts at login: the installed app (tool/install-linux.sh), or this very
  /// binary when it runs from somewhere else (a build folder).
  static String get appBinary => File(installedBinary).existsSync() ? installedBinary : Platform.resolvedExecutable;

  static Future<bool> autostartEnabled() => File(AgendaPaths.autostartFile).exists();

  /// The binary the autostart entry launches, or null without an entry.
  static Future<String?> autostartTarget() async {
    final f = File(AgendaPaths.autostartFile);
    if (!await f.exists()) return null;
    final m = RegExp(r'^Exec=(\S+)', multiLine: true).firstMatch(await f.readAsString());
    return m?.group(1);
  }

  /// Makes the login entry match [on]: writes it when missing or when it points at a
  /// binary that is gone or no longer the one to use, removes it when off.
  static Future<void> ensureAutostart(bool on) async {
    final target = await autostartTarget();
    if (!on) {
      if (target != null) await setAutostart(false);
      return;
    }
    if (target == null || target != appBinary || !await File(target).exists()) await setAutostart(true);
  }

  /// Writes or removes ~/.config/autostart/agenda.desktop.
  static Future<void> setAutostart(bool on) async {
    final f = File(AgendaPaths.autostartFile);
    if (!on) {
      if (await f.exists()) await f.delete();
      return;
    }
    final bin = appBinary;
    final dir = File(bin).parent.path;
    final icon = File('$dir/icon.png').existsSync() ? '$dir/icon.png' : '$dir/data/flutter_assets/assets/icon.png';
    await f.parent.create(recursive: true);
    await f.writeAsString('''
[Desktop Entry]
Type=Application
Name=agenda
Comment=Claude-powered assistant for the daily tasks
Exec=$bin --start-minimized
Path=$dir
Icon=$icon
Terminal=false
StartupNotify=false
StartupWMClass=x1watt.agenda
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
''');
  }

  static Future<ProcessResult> _systemctl(List<String> args) => Process.run('systemctl', ['--user', ...args]);

  static Future<bool> timerEnabled() async =>
      (await _systemctl(['is-enabled', timer])).stdout.toString().trim() == 'enabled';

  static Future<void> setTimer(bool on) async {
    await _systemctl([on ? 'enable' : 'disable', '--now', timer]);
  }

  /// Changes the tick interval with a drop-in, then reloads the timer.
  static Future<void> setInterval(int minutes) async {
    final dir = Directory('${AgendaPaths.systemdUserDir}/$timer.d');
    await dir.create(recursive: true);
    await File('${dir.path}/interval.conf').writeAsString('[Timer]\nOnUnitActiveSec=\nOnUnitActiveSec=${minutes}min\n');
    await _systemctl(['daemon-reload']);
    if (await timerEnabled()) await _systemctl(['restart', timer]);
  }

  /// Next tick of the timer, or null if it is not scheduled.
  static Future<DateTime?> nextCheck() async {
    // The timer is monotonic, so `show` has no realtime value; list-timers
    // prints the next run first, e.g. "Fri 2026-09-11 16:22:29 CEST 23min ...".
    final r = await _systemctl(['list-timers', timer, '--no-legend', '--no-pager']);
    final m = RegExp(r'^\S+ (\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})').firstMatch(r.stdout.toString().trim());
    return m == null ? null : DateTime.tryParse('${m[1]} ${m[2]}');
  }

  /// Asks the checker for a full run right away.
  static Future<void> runNow() async {
    await File(AgendaPaths.runNowFlag).create(recursive: true);
    await _systemctl(['start', '--no-block', service]);
  }

  static Future<void> openPath(String path) async {
    if (Platform.isAndroid) {
      if (path.startsWith('http://') || path.startsWith('https://') || path.startsWith('mailto:')) {
        await launchUrl(Uri.parse(path), mode: LaunchMode.externalApplication);
      } else {
        await OpenFilex.open(path);
      }
      return;
    }
    await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
  }
}
