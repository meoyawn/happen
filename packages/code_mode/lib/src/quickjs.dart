import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:protocol/protocol.dart';

import 'bindings.dart';
import 'cancellation.dart';
import 'output.dart';

export 'bindings.dart' show nativeThreadId;

typedef HostTool = Future<Object?> Function(String name, Object? arguments, {
  required CancellationToken cancellation,
});

/// A runtime belongs to exactly one Dart isolate, never used concurrently.
class QuickJs {
  QuickJs({int memoryLimit = 32 * 1024 * 1024}) : _handle = jsNew(memoryLimit) {
    if (_handle == nullptr) {
      throw StateError('Could not allocate QuickJS runtime');
    }
  }
  Pointer<Void> _handle;
  bool _running = false;

  Object? evaluate(String source, {int cpuBudgetMs = 1000}) {
    if (_handle == nullptr) throw StateError('QuickJS is closed');
    final native = source.toNativeUtf8();
    try {
      return _decode(jsEval(_handle, native, cpuBudgetMs));
    } finally {
      malloc.free(native);
    }
  }

  Object? _decode(Pointer<Utf8> pointer) {
    if (pointer == nullptr) throw StateError('QuickJS allocation failed');
    try {
      final value = pointer.toDartString();
      if (value.startsWith('E')) throw StateError(value.substring(1));
      return jsonDecode(value.substring(1));
    } finally {
      jsStringFree(pointer);
    }
  }

  void resetContext() {
    if (_running) throw StateError('Cannot reset an executing cell');
    jsResetContext(_handle);
  }

  Future<Json> run(
    String source, {
    required HostTool tool,
    required CancellationToken cancellation,
    Json values = const {},
    List<Json> catalog = const [],
    Duration timeout = const Duration(seconds: 60),
    int cpuBudgetMs = 1000,
    bool awaitPending = true,
  }) async {
    cancellation.throwIfCancelled();
    if (_running) throw StateError('Only one cell may run in a context');
    if (source.length > 256 * 1024) {
      throw const FormatException('Cell source too large');
    }
    final maxOutputTokens = cellOutputTokens(source);
    final cell = cancellation is CodeCancellationToken
        ? CodeCancellationToken.shared(cancellation.address, generation: cancellation.generation)
        : CodeCancellationToken();
    final link = CancellationHook(cancellation, cell.cancel);
    final deadline = Timer(timeout, () => cell.cancel(TimeoutException('JavaScript cell timed out', timeout)));
    _running = true;
    final pending = <int, Future<void>>{};
    final replies = <Json>[];
    final clock = Stopwatch()..start();
    int budget() {
      cell.throwIfCancelled();
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        cell.cancel(TimeoutException('JavaScript cell timed out', timeout));
        cell.throwIfCancelled();
      }
      return cpuBudgetMs.clamp(1, remaining.inMilliseconds.clamp(1, cpuBudgetMs));
    }
    Object? evaluateCell(String source) => evaluate(source, cpuBudgetMs: budget());
    jsSetInterrupt(_handle, Pointer.fromAddress(cell.address), cell.generation);
    try {
      evaluateCell(_bootstrap);
      evaluateCell('ALL_TOOLS.push(...${jsonEncode(catalog)}); null');
      evaluateCell('__cell.values = ${jsonEncode(values)}; null');
      evaluateCell(
        '__cell.start(${jsonEncode(source)}); null',
      );
      while (true) {
        budget();
        while (replies.isNotEmpty) {
          evaluateCell(
            '__cell.resolve(${jsonEncode(replies.removeAt(0))}); null',
          );
        }
        final error = jsPump(_handle, 128, budget());
        if (error != nullptr) _decode(error);
        final state = jsonObject(evaluateCell('__cell.poll()'));
        if (state['error'] != null) throw StateError(state['error'] as String);
        for (final raw in state['requests'] as List) {
          budget();
          final request = jsonObject(raw);
          final id = request['id'] as int;
          final operation = Future<Object?>.sync(
            () => tool(request['name'] as String, request['args'] ?? {}, cancellation: cell),
          );
          pending[id] = operation.then<void>(
            (value) {
              if (!cell.isCancelled) replies.add({'id': id, 'ok': true, 'value': value});
            },
            onError: (Object error, StackTrace stack) {
              if (!cell.isCancelled) replies.add({'id': id, 'ok': false, 'value': error.toString()});
            },
          );
          unawaited(pending[id]!.whenComplete(() => pending.remove(id)));
        }
        if (state['done'] == true && (!awaitPending || pending.isEmpty && replies.isEmpty)) {
          final result = jsonObject(evaluateCell(
            '({output: __cell.output.collect(), values: __cell.values})',
          ));
          return {
            'output': renderCellOutput(jsonObject(result['output']), maxOutputTokens),
            'values': result['values'],
          };
        }
        // Let cancellation and async host I/O run between bounded native calls.
        if (jsHasJobs(_handle) == 0 && replies.isEmpty) {
          await Future.any<void>(pending.values)
              .asCancellable(cell);
        } else {
          await cancellableDelay(Duration.zero, cell);
        }
      }
    } catch (_) {
      // Native execution may observe the atomic signal before Dart can service
      // the cancellation mailbox or deadline timer.
      budget();
      rethrow;
    } finally {
      deadline.cancel();
      link.dispose();
      cell.cancel();
      await Future.wait(pending.values.toList());
      replies.clear();
      jsSetInterrupt(_handle, nullptr, 0);
      cell.close();
      _running = false;
    }
  }

  void close() {
    if (_handle != nullptr) {
      jsFree(_handle);
      _handle = nullptr;
    }
  }
}

const _bootstrap = outputBootstrap + r'''
var ALL_TOOLS = [];
var __cell = (() => {
  const pending = new Map();
  const requests = [];
  const output = __createOutput();
  let next = 1, done = false, error = null;
  const api = {
    values: {}, output,
    start(source) {
      const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
      new AsyncFunction(source)().then(
        value => { if (value !== undefined) text(value); done = true; },
        cause => { error = String(cause) + (cause && cause.stack ? "\n" + cause.stack : ""); done = true; }
      );
    },
    poll() {
      return {done, error, requests: requests.splice(0)};
    },
    resolve(reply) {
      const item = pending.get(reply.id);
      if (!item) throw new Error("Unknown host call");
      pending.delete(reply.id);
      if (reply.ok) item.resolve(reply.value);
      else item.reject(new Error(String(reply.value)));
    }
  };
  function text(value) {
    const content = typeof value === "string" ? value : JSON.stringify(value) ?? String(value);
    output.push(content);
  }
  function store(key, value) {
    const encoded = JSON.stringify(value);
    if (encoded === undefined) throw new Error("store requires a JSON value");
    api.values[String(key)] = JSON.parse(encoded);
  }
  function load(key) { return api.values[String(key)]; }
  const tools = new Proxy({}, {
    get(_, name) {
      return args => {
        if (pending.size >= 64) throw new Error("Too many outstanding host calls");
        const id = next++;
        requests.push({id, name: String(name), args: args ?? {}});
        return new Promise((resolve, reject) => { pending.set(id, {resolve, reject}); });
      };
    }
  });
  for (const [name, value] of Object.entries({text, store, load, tools, console: {log: text}})) {
    globalThis[name] = value;
  }
  return api;
})();
''';
