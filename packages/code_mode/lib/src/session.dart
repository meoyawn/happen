import 'dart:async';

import 'package:protocol/protocol.dart';

import 'cancellation.dart';
import 'content.dart';
import 'output.dart';
import 'quickjs.dart';

/// Owns actual interpreters between exec/wait observations. An observation's
/// deadline yields output; it never cancels the interpreter or its host calls.
class CodeSession {
  CodeSession(this.cancellation);
  final CancellationToken cancellation;
  final _cells = <String, _Cell>{};
  bool _closed = false;
  Json? _values;
  int _nextCell = 1;
  bool get hasRunningCells => _cells.values.any((cell) => cell.result == null);

  Future<Json> execute(String source, {
    required HostTool tool,
    required CancellationToken cancellation,
    required Json values,
    required List<Json> catalog,
    Future<void> Function(String)? notify,
  }) async {
    this.cancellation.throwIfCancelled();
    cancellation.throwIfCancelled();
    if (_closed) throw StateError('Code mode session is closed');
    final parsed = parseExecSource(source);
    if (source.length > 256 * 1024) throw const FormatException('Cell source too large');
    if (_cells.length >= 32) throw StateError('Too many uncollected exec cells');
    final cell = _Cell();
    final id = '${_nextCell++}';
    _cells[id] = cell;
    final link = CancellationHook(this.cancellation, cell.cancellation.cancel);
    cell.done = () async {
      Json result;
      try {
        result = await cell.engine.run(parsed.code, tool: tool, values: _values ??= {...values},
          catalog: catalog, cancellation: cell.cancellation, timeout: null,
          interrupt: cancellation is CodeCancellationToken ? cancellation : null,
          awaitPending: false, retainOutput: true,
          module: true,
          onYield: () { cell.yielded = true; cell.changed(); }, onNotify: notify);
      } catch (error) {
        result = {'error': error is StateError ? error.message.toString() : error.toString()};
      }
      try {
        Json output;
        try { output = cell.engine.takeCollectedOutput(); }
        catch (_) { output = {'output': {'head': <String>[], 'tail': <String>[], 'omittedBytes': 0, 'omittedItems': 0}}; }
        if (!cell.cancellation.isCancelled) {
          try {
            final writes = jsonObject(result['writes'] ?? cell.engine.evaluate('__cell.writes'));
            _values!.addAll(writes);
          } catch (error) {
            result.putIfAbsent('error', () => error.toString());
          }
        }
        cell.result = {...result..remove('writes')..remove('values'), 'collected': output['output']};
      } finally {
        cell.engine.close();
        cell.cancellation.cancel();
        link.dispose();
        cell.changed();
      }
    }();
    return _observe(id, cell, parsed.yieldTimeMs, parsed.maxOutputTokens, cancellation);
  }

  Future<Json> wait(Json input, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    final id = requiredString(input, 'cell_id');
    final yieldTime = _integer(input, 'yield_time_ms', 10000);
    final maxTokens = _integer(input, 'max_tokens', 10000);
    if (input['terminate'] != null && input['terminate'] is! bool) {
      throw const FormatException('terminate must be a boolean');
    }
    final cell = _cells[id];
    if (cell == null) return {'error': 'exec cell $id not found', 'output': <String>[]};
    if (input['terminate'] == true) {
      cell.terminated = true;
      cell.cancellation.cancel();
    }
    return _observe(id, cell, yieldTime, maxTokens, cancellation);
  }

  Future<Json> _observe(String id, _Cell cell, int milliseconds, int tokens, CancellationToken token) async {
    if (cell.observing) throw StateError('A wait is already pending for cell $id');
    cell.observing = true;
    final watch = Stopwatch()..start();
    final hook = CancellationHook(token, cell.cancellation.cancel);
    // Codex grants a one-second completion grace for waits of at least 10s.
    final ready = Completer<void>();
    final timer = Timer(Duration(milliseconds: milliseconds + (milliseconds >= 10000 ? 1000 : 0)), ready.complete);
    try {
      if (cell.terminated) await cell.done.asCancellable(token);
      while (cell.result == null && !cell.yielded && !ready.isCompleted) {
        await Future.any([cell.change.future, ready.future]).asCancellable(token);
      }
      token.throwIfCancelled();
      cell.yielded = false;
      final completed = cell.result;
      final Json result;
      if (completed == null) { result = cell.engine.takeOutput(maxTokens: tokens); }
      else {
        final collected = jsonObject(completed['collected']);
        if (completed['error'] != null && !cell.terminated) collected['tail'] = [...(collected['tail'] as List), 'Script error:\n${completed['error']}'];
        final rendered = renderCellContent(collected, tokens);
        result = {...completed..remove('collected'), 'content': rendered.items,
          'output': rendered.items.where((part) => part['type'] == 'input_text').map((part) => part['text']).toList(),
          if (rendered.items.any((part) => part['type'] != 'input_text')) 'text_audio_tokens': rendered.textAudioTokens};
      }
      if (completed != null) _cells.remove(id);
      return {
        ...result,
        'values': {...?_values},
        if (completed == null) 'cell_id': id,
        if (cell.terminated) 'terminated': true,
        'wall_time_seconds': watch.elapsedMicroseconds / 1000000,
      }..removeWhere((key, value) => key == 'error' && cell.terminated);
    } on CancelledException {
      cell.cancellation.cancel();
      await cell.done;
      _cells.remove(id);
      rethrow;
    } finally {
      timer.cancel(); hook.dispose(); cell.observing = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    final cells = _cells.values.toList();
    for (final cell in cells) { cell.cancellation.cancel(); }
    await Future.wait(cells.map((cell) => cell.done));
    _cells.clear();
  }
}

int _integer(Json input, String name, int fallback) {
  final value = input[name];
  if (value == null) return fallback;
  if (value is! num || !value.isFinite || value < 0 || value > 9007199254740991 || value != value.truncateToDouble()) {
    throw FormatException('$name must be a non-negative safe integer');
  }
  return value.toInt();
}

class _Cell {
  final engine = QuickJs(memoryLimit: 256 * 1024 * 1024);
  final cancellation = CancellationToken();
  late final Future<void> done;
  Json? result;
  bool yielded = false, terminated = false, observing = false;
  var change = Completer<void>();
  void changed() {
    final previous = change;
    change = Completer<void>();
    previous.complete();
  }
}
