import 'dart:convert';
import 'dart:io';

import 'claude_process.dart';

/// A Claude Code session transcript (~/.claude/projects/<cwd>/<id>.jsonl).
class SessionInfo {
  SessionInfo({
    required this.id,
    required this.path,
    required this.title,
    required this.lastActivity,
    required this.sizeBytes,
  });

  final String id;
  final String path;
  final String title;
  final DateTime lastActivity;
  final int sizeBytes;
}

enum ChatRole { user, assistant, tool, notice }

/// One rendered line of a conversation.
class ChatItem {
  ChatItem(this.role, this.text, {this.detail, this.isError = false, this.time});

  final ChatRole role;
  String text;

  /// For tool items: a short excerpt of the tool result.
  String? detail;
  bool isError;
  final DateTime? time;
}

final _reminder = RegExp(r'<system-reminder>[\s\S]*?</system-reminder>');

/// User text as typed, or null for harness noise (reminders, command wrappers).
String? cleanUserText(String raw) {
  final t = raw.replaceAll(_reminder, '').trim();
  if (t.isEmpty) return null;
  if (t.startsWith('<command-') || t.startsWith('<local-command') || t.startsWith('Caveat:')) {
    return null;
  }
  return t;
}

/// Lists sessions newest first. Reads only the head and tail of each file.
Future<List<SessionInfo>> listSessions(String projectDir) async {
  final dir = Directory(projectDir);
  if (!await dir.exists()) return const [];
  final out = <SessionInfo>[];
  await for (final f in dir.list()) {
    if (f is! File || !f.path.endsWith('.jsonl')) continue;
    try {
      final stat = await f.stat();
      out.add(SessionInfo(
        id: f.uri.pathSegments.last.replaceAll('.jsonl', ''),
        path: f.path,
        title: await _sessionTitle(f, stat.size),
        lastActivity: stat.modified,
        sizeBytes: stat.size,
      ));
    } on FileSystemException {
      continue;
    }
  }
  out.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
  return out;
}

Future<String> _sessionTitle(File f, int size) async {
  const window = 128 * 1024;
  final raf = await f.open();
  try {
    final head = utf8.decode(await raf.read(window), allowMalformed: true);
    var tail = '';
    if (size > window) {
      await raf.setPosition(size - window);
      tail = utf8.decode(await raf.read(window), allowMalformed: true);
    }
    String? name, aiTitle, firstPrompt;
    for (final line in [...const LineSplitter().convert(head), ...const LineSplitter().convert(tail)]) {
      if (!line.startsWith('{')) continue;
      final Object? j;
      try {
        j = jsonDecode(line);
      } on FormatException {
        continue; // cut at the window edge
      }
      if (j is! Map<String, Object?>) continue;
      switch (j['type']) {
        case 'agent-name' || 'custom-title':
          name = (j['agentName'] ?? j['customTitle']) as String? ?? name;
        case 'ai-title':
          aiTitle = j['aiTitle'] as String? ?? aiTitle;
        case 'user' when firstPrompt == null && j['isMeta'] != true && j['isSidechain'] != true:
          final m = j['message'];
          if (m is Map<String, Object?>) {
            final c = m['content'];
            final text = c is String ? c : contentText(c);
            firstPrompt = cleanUserText(text);
          }
      }
    }
    final t = name ?? aiTitle ?? firstPrompt ?? '(empty session)';
    final one = t.split('\n').first;
    return one.length > 80 ? '${one.substring(0, 80)}...' : one;
  } finally {
    await raf.close();
  }
}

/// Reads a transcript into chat items. Blocking; call it off the UI isolate.
List<ChatItem> readTranscriptSync(String path) =>
    parseTranscript(File(path).readAsLinesSync());

List<ChatItem> parseTranscript(Iterable<String> lines) {
  final items = <ChatItem>[];
  final toolsById = <String, ChatItem>{};
  for (final line in lines) {
    if (!line.startsWith('{')) continue;
    final Object? j;
    try {
      j = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (j is! Map<String, Object?>) continue;
    if (j['isSidechain'] == true || j['isMeta'] == true) continue;
    final type = j['type'];
    if (type != 'user' && type != 'assistant') continue;
    final m = j['message'];
    if (m is! Map<String, Object?>) continue;
    final time = DateTime.tryParse('${j['timestamp'] ?? ''}')?.toLocal();
    final c = m['content'];
    if (c is String) {
      final t = type == 'user' ? cleanUserText(c) : c.trim();
      if (t != null && t.isNotEmpty) {
        items.add(ChatItem(type == 'user' ? ChatRole.user : ChatRole.assistant, t, time: time));
      }
      continue;
    }
    if (c is! List) continue;
    for (final b in c.whereType<Map<String, Object?>>()) {
      switch ((type, b['type'])) {
        case ('user', 'text'):
          final t = cleanUserText('${b['text'] ?? ''}');
          if (t != null) items.add(ChatItem(ChatRole.user, t, time: time));
        case ('user', 'tool_result'):
          final tool = toolsById['${b['tool_use_id']}'];
          if (tool != null) {
            final r = contentText(b['content']).trim();
            tool.detail = r.length > 600 ? '${r.substring(0, 600)}...' : r;
            tool.isError = b['is_error'] == true;
          }
        case ('assistant', 'text'):
          final t = '${b['text'] ?? ''}'.trim();
          if (t.isNotEmpty) items.add(ChatItem(ChatRole.assistant, t, time: time));
        case ('assistant', 'tool_use'):
          final input = b['input'];
          final item = ChatItem(
            ChatRole.tool,
            toolSummary('${b['name']}', input is Map<String, Object?> ? input : const {}),
            time: time,
          );
          toolsById['${b['id']}'] = item;
          items.add(item);
      }
    }
  }
  return items;
}
