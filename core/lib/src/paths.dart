import 'dart:io';

/// Well-known locations shared by the app and the background checker.
class AgendaPaths {
  AgendaPaths(this.agendaDir);

  /// The agenda folder itself (CLAUDE.md, projects/, general.json, runs/).
  final String agendaDir;

  /// Set on Android, where there is no HOME: the app's private support folder.
  static String? homeOverride;

  static String get home =>
      homeOverride ?? Platform.environment['HOME'] ?? Directory.current.path;

  static String get defaultAgendaDir => '$home/code/2026/agenda';

  static String get configDir => '$home/.config/agenda';
  static String get settingsFile => '$configDir/settings.json';
  static String get stateDir => '$home/.local/state/agenda';
  static String get stateFile => '$stateDir/state.json';
  static String get cacheDir => '$home/.cache/agenda';
  static String get checkLock => '$cacheDir/check.lock';
  static String get chatLock => '$cacheDir/chat.lock';
  static String get runNowFlag => '$cacheDir/run-now';
  static String get autostartFile => '$home/.config/autostart/agenda.desktop';
  static String get systemdUserDir => '$home/.config/systemd/user';
  static String get installDir => '$home/.local/opt/agenda';

  /// Central personal information (identity, family, IDs, bank, documents), outside the agenda.
  static String get personalDir => '$home/personal';

  String get projectsDir => '$agendaDir/projects';
  String get generalFile => '$agendaDir/general.json';
  String get legacyDir => '$agendaDir/legacy';
  String get legacyTasksFile => '$legacyDir/tasks.json';
  String get docsFormat => '$agendaDir/docs/format.md';

  /// The folder above the agenda (`~/code/2026`), where the old project symlinks live.
  String get workspaceDir => Directory(agendaDir).parent.path;

  String projectDir(String id) => '$projectsDir/$id';
  String get runsDir => '$agendaDir/runs';
  String get reviewPrompt => '$agendaDir/prompts/review.md';
  String get accountsDir => '$agendaDir/accounts';

  /// The Anthropic API key used by the phone app (handed over when pairing).
  String get apiKeyFile => '$accountsDir/anthropic-api.pass';

  /// Desktop sync server: certificate, key and paired devices.
  static String get syncDir => '$configDir/sync';

  /// Where Claude Code keeps the transcripts of sessions started in [agendaDir].
  String get claudeProjectDir => claudeProjectDirFor(agendaDir);

  static String claudeProjectDirFor(String cwd) =>
      '$home/.claude/projects/${cwd.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-')}';

  /// Resolves `claude`: the user-local install first, then PATH. Checked once.
  static final String claudeBinary = () {
    final local = '$home/.local/bin/claude';
    return File(local).existsSync() ? local : 'claude';
  }();
}

/// Writes [contents] to [path] atomically (temp file + rename), creating parents.
Future<void> writeAtomic(String path, String contents) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final tmp = File('$path.tmp-$pid');
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(path);
}

/// Collapses `.`, `..` and empty segments of an absolute path.
String normalizePath(String path) {
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(part);
    }
  }
  return '/${out.join('/')}';
}

/// Relative path from [from] (a directory) to [to].
String relativeTo(String from, String to) {
  final a = normalizePath(from).split('/').where((s) => s.isNotEmpty).toList();
  final b = normalizePath(to).split('/').where((s) => s.isNotEmpty).toList();
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  return [for (var k = i; k < a.length; k++) '..', ...b.sublist(i)].join('/');
}
