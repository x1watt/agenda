import 'dart:convert';
import 'dart:io';

/// The file tools Claude gets on the phone. They mirror Claude Code's Read, Write,
/// Edit, Glob and Grep (same names and input keys, so the chat shows them the same
/// way) and only reach the agenda folder and ~/personal.
class FileTools {
  FileTools({required this.agendaDir, required this.personalDir});

  final String agendaDir;
  final String personalDir;

  static const _maxRead = 400 * 1024;
  static const _imageTypes = {'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'webp': 'image/webp', 'gif': 'image/gif'};

  /// Tool definitions for the Messages API.
  static List<Map<String, Object?>> get definitions => [
    _tool('Read', 'Read a file. Text comes back with line numbers; PDFs and images come back as documents or images you can see.', {
      'file_path': _s('Path: relative to the agenda folder (e.g. projects/taxes/data/TASKS.md), or starting with ~/personal/'),
      'offset': {'type': 'integer', 'description': 'First line to read (1-based), for long files'},
      'limit': {'type': 'integer', 'description': 'Number of lines to read'},
    }, ['file_path']),
    _tool('Write', 'Create or overwrite a whole file. Prefer Edit for changes to an existing file.', {
      'file_path': _s('Path as for Read'),
      'content': _s('The complete new file content'),
    }, ['file_path', 'content']),
    _tool('Edit', 'Replace an exact string in a file. old_string must occur exactly once unless replace_all is true. Keep JSON files valid.', {
      'file_path': _s('Path as for Read'),
      'old_string': _s('Exact text to replace, including indentation'),
      'new_string': _s('Replacement text'),
      'replace_all': {'type': 'boolean', 'description': 'Replace every occurrence'},
    }, ['file_path', 'old_string', 'new_string']),
    _tool('Glob', 'List files matching a glob pattern (supports * and **), newest first.', {
      'pattern': _s('For example projects/**/task.json or ~/personal/*.md'),
    }, ['pattern']),
    _tool('Grep', 'Search file contents with a regular expression. Returns path:line: text.', {
      'pattern': _s('Regular expression'),
      'path': _s('Folder or file to search, as for Read; default the agenda folder'),
      'case_insensitive': {'type': 'boolean'},
    }, ['pattern']),
  ];

  static Map<String, Object?> _s(String d) => {'type': 'string', 'description': d};

  static Map<String, Object?> _tool(String name, String description, Map<String, Object?> props, List<String> required) => {
    'name': name,
    'description': description,
    'input_schema': {'type': 'object', 'properties': props, 'required': required, 'additionalProperties': false},
    'eager_input_streaming': true,
  };

  /// Absolute path for a tool path, or null when it leaves the two folders.
  String? resolve(String raw) {
    var p = raw.trim();
    String abs;
    if (p.startsWith('~/personal')) {
      abs = '$personalDir${p.substring('~/personal'.length)}';
    } else if (p.startsWith('/')) {
      abs = p;
    } else {
      if (p.startsWith('./')) p = p.substring(2);
      abs = '$agendaDir/$p';
    }
    final norm = _normalize(abs);
    bool inside(String root) => norm == root || norm.startsWith('$root/');
    return inside(_normalize(agendaDir)) || inside(_normalize(personalDir)) ? norm : null;
  }

  static String _normalize(String path) {
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

  /// How a path is shown back to Claude.
  String display(String abs) {
    if (abs.startsWith('$personalDir/')) return '~/personal/${abs.substring(personalDir.length + 1)}';
    if (abs.startsWith('$agendaDir/')) return abs.substring(agendaDir.length + 1);
    return abs;
  }

  /// Checks the input against the tool's schema (inputs stream in and may be cut off).
  static String? validate(String name, Map<String, Object?> input) {
    final def = definitions.where((d) => d['name'] == name).firstOrNull;
    if (def == null) return 'unknown tool $name';
    final schema = def['input_schema']! as Map<String, Object?>;
    for (final r in (schema['required']! as List).cast<String>()) {
      if (input[r] is! String) return 'missing or invalid "$r"';
    }
    return null;
  }

  /// Runs one tool. Returns the tool_result content (a string or content blocks) and whether it failed.
  Future<(Object, bool)> run(String name, Map<String, Object?> input) async {
    final problem = validate(name, input);
    if (problem != null) return ('Invalid input: $problem', true);
    try {
      return switch (name) {
        'Read' => await _read(input),
        'Write' => await _write(input),
        'Edit' => await _edit(input),
        'Glob' => await _glob(input),
        'Grep' => await _grep(input),
        _ => ('unknown tool $name', true),
      };
    } on FileSystemException catch (e) {
      return ('${e.message}: ${e.path ?? ''}', true);
    }
  }

  (Object, bool) _outside(String p) => ('$p is outside the agenda folder and ~/personal; only those can be used on the phone.', true);

  Future<(Object, bool)> _read(Map<String, Object?> input) async {
    final abs = resolve('${input['file_path']}');
    if (abs == null) return _outside('${input['file_path']}');
    final f = File(abs);
    if (await Directory(abs).exists()) {
      final names = [await for (final e in Directory(abs).list()) '${e.path.split('/').last}${e is Directory ? '/' : ''}']..sort();
      return ('Directory ${display(abs)}:\n${names.join('\n')}', false);
    }
    if (!await f.exists()) return ('File not found: ${display(abs)}', true);
    final ext = abs.split('.').last.toLowerCase();
    final size = await f.length();
    if (_imageTypes.containsKey(ext)) {
      if (size > 5 * 1024 * 1024) return ('Image too large to view (${size ~/ 1024} KB)', true);
      return (
        [
          {
            'type': 'image',
            'source': {'type': 'base64', 'media_type': _imageTypes[ext], 'data': base64.encode(await f.readAsBytes())},
          },
        ],
        false,
      );
    }
    if (ext == 'pdf') {
      if (size > 20 * 1024 * 1024) return ('PDF too large to read (${size ~/ 1024} KB)', true);
      return (
        [
          {
            'type': 'document',
            'source': {'type': 'base64', 'media_type': 'application/pdf', 'data': base64.encode(await f.readAsBytes())},
          },
        ],
        false,
      );
    }
    if (size > _maxRead * 4) return ('File too large (${size ~/ 1024} KB); use Grep or offset/limit.', true);
    final String text;
    try {
      text = await f.readAsString();
    } on FormatException {
      return ('Not a text file: ${display(abs)}', true);
    }
    final lines = text.split('\n');
    final offset = ((input['offset'] as num?)?.toInt() ?? 1).clamp(1, lines.length + 1);
    final limit = (input['limit'] as num?)?.toInt() ?? 2000;
    final end = (offset - 1 + limit).clamp(0, lines.length);
    final b = StringBuffer();
    for (var i = offset - 1; i < end; i++) {
      b.writeln('${(i + 1).toString().padLeft(6)}\t${lines[i]}');
    }
    if (end < lines.length) b.writeln('... ${lines.length - end} more lines (use offset)');
    return (b.toString(), false);
  }

  Future<void> _atomic(String abs, String content) async {
    final f = File(abs);
    await f.parent.create(recursive: true);
    final tmp = File('$abs.tmp-${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(abs);
  }

  String? _jsonProblem(String abs, String content) {
    if (!abs.endsWith('.json')) return null;
    try {
      jsonDecode(content);
      return null;
    } on FormatException catch (e) {
      return 'Not written: the result is not valid JSON (${e.message}).';
    }
  }

  Future<(Object, bool)> _write(Map<String, Object?> input) async {
    final abs = resolve('${input['file_path']}');
    if (abs == null) return _outside('${input['file_path']}');
    final content = '${input['content']}';
    final bad = _jsonProblem(abs, content);
    if (bad != null) return (bad, true);
    await _atomic(abs, content);
    return ('Wrote ${display(abs)} (${content.length} characters).', false);
  }

  Future<(Object, bool)> _edit(Map<String, Object?> input) async {
    final abs = resolve('${input['file_path']}');
    if (abs == null) return _outside('${input['file_path']}');
    final f = File(abs);
    if (!await f.exists()) return ('File not found: ${display(abs)}', true);
    final text = await f.readAsString();
    final oldS = '${input['old_string']}', newS = '${input['new_string']}';
    final count = oldS.isEmpty ? 0 : oldS.allMatches(text).length;
    if (count == 0) return ('old_string not found in ${display(abs)}. Read the file again and copy the text exactly.', true);
    final all = input['replace_all'] == true;
    if (count > 1 && !all) return ('old_string occurs $count times; add more context or set replace_all.', true);
    final updated = all ? text.replaceAll(oldS, newS) : text.replaceFirst(oldS, newS);
    final bad = _jsonProblem(abs, updated);
    if (bad != null) return (bad, true);
    await _atomic(abs, updated);
    return ('Edited ${display(abs)} ($count replacement${count == 1 ? '' : 's'}).', false);
  }

  /// Files under both roots as tool paths.
  Future<List<(String, File)>> _allFiles() async {
    final out = <(String, File)>[];
    for (final root in [agendaDir, personalDir]) {
      final d = Directory(root);
      if (!await d.exists()) continue;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File && !e.path.contains('.tmp-')) out.add((display(e.path), e));
      }
    }
    return out;
  }

  static RegExp _globRegex(String pattern) {
    final b = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == '*' && i + 1 < pattern.length && pattern[i + 1] == '*') {
        b.write('.*');
        i++;
        if (i + 1 < pattern.length && pattern[i + 1] == '/') i++;
      } else if (c == '*') {
        b.write('[^/]*');
      } else if (c == '?') {
        b.write('[^/]');
      } else {
        b.write(RegExp.escape(c));
      }
    }
    b.write(r'$');
    return RegExp(b.toString());
  }

  Future<(Object, bool)> _glob(Map<String, Object?> input) async {
    final re = _globRegex('${input['pattern']}'.replaceFirst(RegExp(r'^\./'), ''));
    final hits = <(String, DateTime)>[];
    for (final (p, f) in await _allFiles()) {
      if (re.hasMatch(p)) hits.add((p, await f.lastModified()));
    }
    hits.sort((a, b) => b.$2.compareTo(a.$2));
    if (hits.isEmpty) return ('No files match.', false);
    return ([for (final h in hits.take(200)) h.$1].join('\n') + (hits.length > 200 ? '\n... ${hits.length - 200} more' : ''), false);
  }

  Future<(Object, bool)> _grep(Map<String, Object?> input) async {
    final RegExp re;
    try {
      re = RegExp('${input['pattern']}', caseSensitive: input['case_insensitive'] != true);
    } on FormatException catch (e) {
      return ('Bad regular expression: ${e.message}', true);
    }
    final scope = input['path'] is String ? resolve('${input['path']}') : _normalize(agendaDir);
    if (scope == null) return _outside('${input['path']}');
    final out = <String>[];
    for (final (p, f) in await _allFiles()) {
      if (f.path != scope && !f.path.startsWith('$scope/')) continue;
      if (await f.length() > 2 * 1024 * 1024) continue;
      final String text;
      try {
        text = await f.readAsString();
      } on FormatException {
        continue;
      }
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (re.hasMatch(lines[i])) {
          final l = lines[i].length > 300 ? '${lines[i].substring(0, 300)}...' : lines[i];
          out.add('$p:${i + 1}: $l');
          if (out.length >= 300) return ('${out.join('\n')}\n... more matches, narrow the pattern', false);
        }
      }
    }
    return (out.isEmpty ? 'No matches.' : out.join('\n'), false);
  }
}
