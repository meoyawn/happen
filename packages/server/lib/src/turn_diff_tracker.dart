// Port of codex-rs/core/src/turn_diff_tracker.rs, ddd1812a5.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:tool_runtime/tool_runtime.dart' show unifiedDiff;

typedef _Path = ({String environment, String path});
typedef _DiffKey = ({_Path left, String? before, _Path right, String? after});

/// Net changes from committed patch deltas; the tracker never reads the workspace.
class TurnDiffTracker {
  TurnDiffTracker({this.displayRoots = const {}});
  final Map<String, String> displayRoots;
  final _baseline = <_Path, String>{}, _current = <_Path, String>{};
  final _origins = <_Path, _Path>{};
  var _rendered = <_DiffKey, String?>{};
  bool _valid = true;
  String? unifiedDiffText;

  void invalidate() { _valid = false; _rendered.clear(); unifiedDiffText = null; }

  void trackDelta(Json delta, {String environment = ''}) {
    if (!_valid) return;
    if (delta['exact'] != true) { invalidate(); return; }
    for (final raw in delta['changes'] as List) {
      final change = jsonObject(raw);
      final source = (environment: environment, path: requiredString(change, 'path'));
      final before = change['oldContent'] as String?;
      final after = change['newContent'] as String?;
      switch (change['type']) {
        case 'A':
          _origins.remove(source);
          if (!_current.containsKey(source) && !_baseline.containsKey(source) && before != null) {
            _baseline[source] = before;
          }
          _current[source] = after!;
        case 'D':
          if (_current.remove(source) == null && !_baseline.containsKey(source) && before != null) {
            _baseline[source] = before;
          }
          _origins.remove(source);
        case 'M':
          if (!_current.containsKey(source) && !_baseline.containsKey(source) && before != null) {
            _baseline[source] = before;
          }
          final destination = change['movePath'] as String?;
          if (destination == null || destination == source.path) {
            _current[source] = after!;
            continue;
          }
          final target = (environment: environment, path: destination);
          final overwritten = change['overwrittenMoveContent'] as String?;
          if (!_current.containsKey(target) && !_baseline.containsKey(target) && overwritten != null) {
            _baseline[target] = overwritten;
          }
          final origin = _origins.remove(source) ?? source;
          _current.remove(source);
          _current[target] = after!;
          _origins.remove(target);
          if (target != origin) _origins[target] = origin;
      }
    }
    _refresh();
  }

  String _display(_Path path) {
    var display = path.path.replaceAll(r'\', '/');
    final root = displayRoots[path.environment]?.replaceAll(r'\', '/').replaceFirst(RegExp(r'/$'), '');
    if (root != null && display.startsWith('$root/')) display = display.substring(root.length + 1);
    return displayRoots.length > 1 && path.environment.isNotEmpty ? '${path.environment}/$display' : display;
  }

  void _refresh() {
    final pairs = <_Path, _Path>{for (final entry in _origins.entries)
      if (!_current.containsKey(entry.value) && _current.containsKey(entry.key) &&
          _baseline.containsKey(entry.value) && !_baseline.containsKey(entry.key)) entry.value: entry.key};
    final destinations = pairs.values.toSet();
    final paths = {..._baseline.keys, ..._current.keys}.toList()
      ..sort((a, b) => _display(a).compareTo(_display(b)));
    final rendered = <_DiffKey, String?>{}, output = StringBuffer();
    for (final path in paths) {
      if (destinations.contains(path)) continue;
      final right = pairs[path] ?? path;
      final key = (left: path, before: _baseline[path], right: right, after: _current[right]);
      final diff = _rendered.containsKey(key) ? _rendered[key] : _render(key);
      rendered[key] = diff;
      if (diff != null) output.write(diff);
    }
    _rendered = rendered;
    unifiedDiffText = output.isEmpty ? null : output.toString();
  }

  String? _render(_DiffKey key) {
    if (key.before == key.after) return null;
    final left = _display(key.left), right = _display(key.right);
    String oid(String? content) => content == null ? '0000000000000000000000000000000000000000'
      : sha1.convert([...utf8.encode('blob ${utf8.encode(content).length}\u0000'), ...utf8.encode(content)]).toString();
    return [
      'diff --git a/$left b/$right\n',
      if (key.before == null) 'new file mode 100644\n',
      if (key.after == null) 'deleted file mode 100644\n',
      'index ${oid(key.before)}..${oid(key.after)}\n',
      unifiedDiff(key.before ?? '', key.after ?? '',
        oldPath: key.before == null ? '/dev/null' : 'a/$left',
        newPath: key.after == null ? '/dev/null' : 'b/$right'),
    ].join();
  }
}
