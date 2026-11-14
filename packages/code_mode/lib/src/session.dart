import 'dart:async';
import 'dart:convert';

import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import 'cancellation.dart';
import 'cell.dart';
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
  Json? _changedValues;
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
    final storedValues = {...(_values ??= {...values})};
    cell.done = () async {
      Json result;
      try {
        result = await runCell(parsed.code, tool: tool, values: storedValues,
          catalog: catalog, cancellation: cell.cancellation, id: id, notify: notify,
          onEvent: (event) {
            if (event.containsKey('output')) cell.appendOutput(event['output']);
            if (event['yield'] == true) { cell.yielded = true; cell.changed(); }
          });
      } catch (error) {
        result = {'error': error is StateError ? error.message : error.toString()};
      }
      try {
        Json output;
        try { output = cell.takeOutput(); }
        catch (_) { output = {'head': <String>[], 'tail': <String>[], 'omittedBytes': 0, 'omittedItems': 0}; }
        if (!cell.cancellation.isCancelled) {
          try {
            final writes = jsonObject(result['writes']);
            if (writes.isNotEmpty) {
              _values!.addAll(writes);
              _changedValues = _values;
            }
          } catch (error) {
            result.putIfAbsent('error', () => error.toString());
          }
        }
        cell.result = {...result..remove('writes')..remove('values'), 'collected': output};
      } finally {
        cell.engine.close();
        cell.cancellation.cancel();
        link.dispose();
        cell.cancellation.close();
        cell.changed();
      }
    }();
    return _observe('exec', id, cell, parsed.yieldTimeMs, parsed.maxOutputTokens, cancellation);
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
    if (input['terminate'] == true && cell.result == null) {
      cell.terminated = true;
      cell.cancellation.cancel();
    }
    return _observe('wait', id, cell, yieldTime, maxTokens, cancellation);
  }

  Future<Json> _observe(String operation, String id, _Cell cell, int milliseconds, int tokens, CancellationToken token) =>
    traceAsync('code_mode.$operation', () async {
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
      if (completed == null) {
        final rendered = renderCellContent(cell.takeOutput(), tokens);
        result = {'content': rendered.items,
          'output': rendered.items.where((part) => part['type'] == 'input_text').map((part) => part['text']).toList(),
          if (rendered.items.any((part) => part['type'] != 'input_text')) 'text_audio_tokens': rendered.textAudioTokens};
      }
      else {
        final collected = jsonObject(completed['collected']);
        if (completed['error'] != null && !cell.terminated) collected['tail'] = [...(collected['tail'] as List), 'Script error:\n${completed['error']}'];
        final rendered = traceSync('code_mode.cell.output.render', () => renderCellContent(collected, tokens),
          category: 'code_mode', includeErrorMessage: false);
        result = {...completed..remove('collected'), 'content': rendered.items,
          'output': rendered.items.where((part) => part['type'] == 'input_text').map((part) => part['text']).toList(),
          if (rendered.items.any((part) => part['type'] != 'input_text')) 'text_audio_tokens': rendered.textAudioTokens};
      }
      if (completed != null) _cells.remove(id);
      traceInstant('code_mode.observed', category: 'code_mode', attributes: {
        'code.cell_id': id, 'code.running': completed == null, 'code.terminated': cell.terminated,
      });
      final changedValues = _changedValues;
      _changedValues = null;
      return {
        ...result,
        if (changedValues != null) 'values': {...changedValues},
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
  }, category: 'code_mode', attributes: {
    'code.cell_id': id, 'code.yield_time_ms': milliseconds, 'code.max_output_tokens': tokens,
    'code.terminate': cell.terminated,
  }, includeErrorMessage: false);

  Future<void> close() async {
    _closed = true;
    final cells = _cells.values.toList();
    for (final cell in cells) { cell.cancellation.cancel(); }
    await Future.wait(cells.map((cell) => cell.done));
    _cells.clear();
    _values = null;
    _changedValues = null;
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
  _Cell() {
    engine.evaluate('${outputBootstrap}var __output = __createOutput();');
  }
  // This disposable collector never executes user code. It shares the runtime's
  // bounded output algorithm while the worker's interpreter may be CPU-bound.
  final engine = QuickJs(memoryLimit: 256 * 1024 * 1024);
  final cancellation = CodeCancellationToken();
  void appendOutput(Object? value) => engine.evaluate('__output.push(${jsonEncode(value)}); null');
  Json takeOutput() => jsonObject(engine.evaluate('(() => { const output = __output.collect(); '
    '__output = __createOutput(); return output; })()'));
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
