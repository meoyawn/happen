import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:protocol/protocol.dart';

/// Harness's live editor session. Audio/request lifetime stays outside
/// this owner; manual edits consume arrived text instead of being overwritten.
class ComposerDictationSession {
  ComposerDictationSession(this.controller, this.replace) : _observed = controller.value {
    controller.addListener(_edited);
  }
  final TextEditingController controller;
  final _lifetime = CancellationToken();
  final void Function(TextSelection range, String text) replace;
  TextEditingValue _observed;
  String _transcript = '';
  int _consumed = 0;
  _DictatedRange? _current;
  final _recoverable = <_DictatedRange>[];
  bool _applying = false;
  bool _closed = false;
  bool _recovering = false;
  String? _pending;
  Completer<void>? _compositionDone;

  bool get _composing => controller.value.composing.isValid && !controller.value.composing.isCollapsed;

  void _edited() {
    if (_applying || _closed) return;
    final next = controller.value;
    if (next.text != _observed.text) {
      final change = _difference(_observed.text, next.text);
      _recoverable.removeWhere((range) => change.from < range.to && change.oldEnd > range.from);
      for (final range in _recoverable) {
        range.from = change.map(range.from, 1);
        range.to = change.map(range.to, -1);
      }
    }
    if (next.text != _observed.text || next.selection != _observed.selection) {
      _consumed = _transcript.length;
      _current = null;
    }
    _observed = next;
    if (!_composing) {
      _compositionDone?.complete();
      _compositionDone = null;
      if (_pending != null) { scheduleMicrotask(() {
        if (_closed || _composing) return;
        final pending = _pending;
        _pending = null;
        if (pending != null) update(pending);
      }); }
    }
  }

  void update(String transcript) {
    if (_closed) return;
    if (_composing) { _pending = transcript; return; }
    if (transcript == _transcript) return;
    _recovering = false;
    var consumed = _mapConsumed(_transcript, transcript, _consumed);
    if (_current == null && consumed > 0) {
      consumed += RegExp(r'^[.!?,;:…。！？、，；：।॥]+(?=\s|$)', unicode: true)
          .firstMatch(transcript.substring(consumed))?.end ?? 0;
    }
    final text = transcript.substring(consumed).trim();
    _transcript = transcript;
    _consumed = consumed;
    if (_current == null && text.isEmpty) return;
    final value = controller.value;
    final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
    final range = _current ?? _DictatedRange(selection.start, selection.end,
      value.text.substring(selection.start, selection.end));
    final left = range.from == 0 ? '' : value.text.substring(range.from - 1, range.from);
    final right = range.to == value.text.length ? '' : value.text.substring(range.to, range.to + 1);
    final leading = text.isNotEmpty && left.isNotEmpty && !RegExp(r'[\s([{“‘]$', unicode: true).hasMatch(left) &&
        RegExp(r'^[\p{L}\p{N}]', unicode: true).hasMatch(text) ? ' ' : '';
    final trailing = RegExp(r'[\p{L}\p{N}\p{M}]$', unicode: true).hasMatch(text) &&
        RegExp(r'^[\p{L}\p{N}]', unicode: true).hasMatch(right) ? ' ' : '';
    final replacement = '$leading$text$trailing';
    final old = value.text.substring(range.from, range.to);
    final difference = _difference(old, replacement);
    final change = _EditorChange(range.from + difference.from, range.from + difference.oldEnd, range.from + difference.newEnd);
    _recoverable.removeWhere((other) => other != range && range.from < other.to && range.to > other.from);
    _applying = true;
    try {
      if (old != replacement) {
        replace(TextSelection(baseOffset: change.from, extentOffset: change.oldEnd),
          replacement.substring(difference.from, difference.newEnd));
      }
      for (final other in _recoverable) {
        if (other == range) continue;
        other.from = change.map(other.from, 1);
        other.to = change.map(other.to, -1);
      }
      range.to = range.from + replacement.length;
      if (!_recoverable.contains(range)) _recoverable.add(range);
      _current = range;
      controller.selection = TextSelection.collapsed(offset: range.to - trailing.length);
      _observed = controller.value;
    } finally { _applying = false; }
  }

  Future<bool> finish(String transcript) async {
    if (_composing && !_closed) {
      try { await (_compositionDone ??= Completer<void>()).future.asCancellable(_lifetime); }
      on CancelledException { return false; }
    }
    if (_closed) return false;
    _pending = null;
    update(transcript);
    return transcript.trim().isNotEmpty;
  }

  void pauseForRecovery() => _recovering = true;

  void dispose({bool cancel = false}) {
    if (_closed) return;
    _applying = true;
    try {
      if (cancel && !_recovering) {
        for (final range in _recoverable.toList()..sort((a, b) => b.from.compareTo(a.from))) {
          replace(TextSelection(baseOffset: range.from, extentOffset: range.to), range.original);
        }
      }
    } finally {
      _closed = true;
      _lifetime.cancel();
      controller.removeListener(_edited);
      _compositionDone?.complete();
      _compositionDone = null;
      _pending = null;
      _recoverable.clear();
    }
  }

  // Map the already consumed prefix across ASR revisions by token edits.
  static int _mapConsumed(String before, String after, int consumed) {
    if (consumed == 0 || after.startsWith(before.substring(0, consumed))) return consumed;
    final tokens = RegExp(r'\s+|[\p{L}\p{N}\p{M}_]+|[^\s]', unicode: true);
    final a = tokens.allMatches(before).map((m) => m[0]!).toList();
    final b = tokens.allMatches(after).map((m) => m[0]!).toList();
    var prefix = 0;
    var offset = 0;
    while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
      offset += a[prefix++].length;
      if (offset >= consumed) return consumed;
    }
    var suffix = 0;
    while (suffix < a.length - prefix && suffix < b.length - prefix &&
        a[a.length - suffix - 1] == b[b.length - suffix - 1]) { suffix++; }
    final rows = a.length - suffix - prefix;
    final columns = b.length - suffix - prefix;
    final oldLength = a.skip(prefix).take(rows).join().length;
    final newLength = b.skip(prefix).take(columns).join().length;
    if (consumed >= offset + oldLength && suffix > 0) return consumed + newLength - oldLength;
    // Avoid quadratic work on an unusually large complete ASR replacement.
    // Preserve manually consumed text instead of resurrecting an old revision.
    if (rows * columns > 250000) return (offset + newLength).clamp(0, after.length);
    final distance = List.generate(rows + 1, (_) => List<int>.filled(columns + 1, 0));
    for (var i = rows; i >= 0; i--) {
      for (var j = columns; j >= 0; j--) {
        distance[i][j] = i == rows ? columns - j : j == columns ? rows - i :
          [distance[i + 1][j] + 1, distance[i][j + 1] + 1,
            distance[i + 1][j + 1] + (a[prefix + i] == b[prefix + j] ? 0 : 1)].reduce((x, y) => x < y ? x : y);
      }
    }
    var i = 0;
    var j = 0;
    var mapped = offset;
    while (i < rows && offset < consumed) {
      final cost = j < columns && a[prefix + i] == b[prefix + j] ? 0 : 1;
      if (j < columns && distance[i][j] == distance[i + 1][j + 1] + cost) {
        offset += a[prefix + i++].length;
        mapped += b[prefix + j++].length;
      } else if (distance[i][j] == distance[i + 1][j] + 1) {
        offset += a[prefix + i++].length;
      } else {
        mapped += b[prefix + j++].length;
      }
    }
    return mapped;
  }
}

class _DictatedRange {
  _DictatedRange(this.from, this.to, this.original);
  int from;
  int to;
  final String original;
}

_EditorChange _difference(String before, String after) {
  var prefix = 0;
  while (prefix < before.length && prefix < after.length && before[prefix] == after[prefix]) { prefix++; }
  var suffix = 0;
  while (suffix < before.length - prefix && suffix < after.length - prefix &&
      before[before.length - suffix - 1] == after[after.length - suffix - 1]) { suffix++; }
  return _EditorChange(prefix, before.length - suffix, after.length - suffix);
}

class _EditorChange {
  _EditorChange(this.from, this.oldEnd, this.newEnd);
  final int from;
  final int oldEnd;
  final int newEnd;
  int map(int position, int association) {
    if (position < from || position == from && (oldEnd != from || association < 0)) return position;
    if (position >= oldEnd) return position + newEnd - oldEnd;
    return association < 0 ? from : newEnd;
  }
}
