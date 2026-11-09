/// Three-way merge of the agenda JSON files (task.json, project.json, events.json,
/// recurring.json, general.json) when both the desktop and the phone changed the same file.
library;

import 'dart:convert';

/// Result of [mergeJson]: the merged document and a note per field where both
/// sides changed the same value differently (the newer side won there).
class JsonMergeResult {
  JsonMergeResult(this.value, this.conflicts);
  final Object? value;
  final List<String> conflicts;
}

const _absent = _Absent();

class _Absent {
  const _Absent();
}

/// How list elements are recognised across versions, by the key holding the list.
/// Lists not named here are treated as plain values.
String? Function(Object?)? _identity(String key) => switch (key) {
  'items' || 'threads' || 'events' || 'topics' => (v) => v is Map ? '${v['id']}' : null,
  'files' => (v) => v is Map ? '${v['path']}' : null,
  'watch' => (v) => v is Map ? '${v['from']}' : null,
  'deadlines' => (v) => v is Map ? '${v['date']}|${v['text']}|${v['task']}' : null,
  // Sets of strings kept by the checker (shared/checker-state.json): union.
  'seen' || 'notified_deadlines' => (v) => '$v',
  // Append-only logs: an entry is its whole content.
  'history' || 'conversation' => (v) => jsonEncode(v),
  _ => null,
};

/// Sort key that keeps append-only logs in time order after a union.
String? _logTime(String key, Object? v) => v is! Map
    ? null
    : switch (key) {
        'history' => '${v['date']}',
        'conversation' => '${v['at']}',
        _ => null,
      };

bool _eq(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_eq(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_eq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Merges [local] and [remote], both derived from [base]. Where both changed the
/// same scalar differently, [localWins] decides (the newer file) and a conflict is noted.
JsonMergeResult mergeJson(Object? base, Object? local, Object? remote, {required bool localWins}) {
  final conflicts = <String>[];
  final v = _merge(base, local, remote, '', localWins, conflicts);
  return JsonMergeResult(v is _Absent ? null : v, conflicts);
}

Object? _merge(Object? b, Object? l, Object? r, String path, bool localWins, List<String> conflicts) {
  if (_eq(l, r)) return l;
  if (_eq(l, b)) return r;
  if (_eq(r, b)) return l;
  if (l is Map && r is Map) {
    final bm = b is Map ? b : const {};
    final out = <String, Object?>{};
    for (final k in {...l.keys, ...r.keys}.cast<String>()) {
      final v = _merge(bm.containsKey(k) ? bm[k] : _absent, l.containsKey(k) ? l[k] : _absent, r.containsKey(k) ? r[k] : _absent, '$path/$k', localWins,
          conflicts);
      if (v is! _Absent) out[k] = v;
    }
    return out;
  }
  final key = path.split('/').last;
  final id = _identity(key);
  if (l is List && r is List && id != null) return _mergeList(b is List ? b.cast<Object?>() : const [], l.cast<Object?>(), r.cast<Object?>(), key, id, path, localWins, conflicts);
  conflicts.add("${path.isEmpty ? '/' : path}: changed on both devices, kept the newer value (${localWins ? 'this device' : 'other device'})");
  return localWins ? l : r;
}

List<Object?> _mergeList(List<Object?> b, List<Object?> l, List<Object?> r, String key, String? Function(Object?) id, String path, bool localWins, List<String> conflicts) {
  Map<String, Object?> byId(List<Object?> xs) => {for (final x in xs) id(x) ?? jsonEncode(x): x};
  final bi = byId(b), li = byId(l), ri = byId(r);
  final order = <String>[...li.keys, ...ri.keys.where((k) => !li.containsKey(k))];
  final out = <Object?>[];
  for (final k in order) {
    final v = _merge(bi.containsKey(k) ? bi[k] : _absent, li.containsKey(k) ? li[k] : _absent, ri.containsKey(k) ? ri[k] : _absent, '$path[$k]', localWins,
        conflicts);
    if (v is! _Absent) out.add(v);
  }
  if (key == 'history' || key == 'conversation') {
    // Stable sort by time so entries from both sides interleave in order.
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
    indexed.sort((a, c) {
      final t = (_logTime(key, a.$2) ?? '').compareTo(_logTime(key, c.$2) ?? '');
      return t != 0 ? t : a.$1.compareTo(c.$1);
    });
    return [for (final e in indexed) e.$2];
  }
  return out;
}
