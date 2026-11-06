import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import 'bindings.dart';
import 'cancellation.dart';
import 'content.dart';
import 'media.dart';
import 'output.dart';

export 'bindings.dart' show nativeThreadId;

typedef HostTool = Future<Object?> Function(String name, Object? arguments, {
  required CancellationToken cancellation,
});

/// A runtime belongs to exactly one Dart isolate, never used concurrently.
class QuickJs {
  QuickJs({int memoryLimit = 32 * 1024 * 1024}) : _handle =
    traceSync('code_mode.runtime.init', () {
      final handle = jsNew(memoryLimit);
      if (handle == nullptr) throw StateError('Could not allocate QuickJS runtime');
      return handle;
    }, category: 'code_mode', attributes: {
      'runtime.name': 'quickjs', 'runtime.memory_limit_bytes': memoryLimit,
      'runtime.includes_initial_context': true,
    }, includeErrorMessage: false);
  Pointer<Void> _handle;
  bool _running = false;
  void Function()? _closeExit;
  void Function()? _closeMedia;
  bool _exited = false;

  Object? evaluate(String source, {int cpuBudgetMs = 1000}) {
    if (_handle == nullptr) throw StateError('QuickJS is closed');
    final native = source.toNativeUtf8();
    try {
      return _decode(jsEval(_handle, native, cpuBudgetMs));
    } finally {
      malloc.free(native);
    }
  }

  void _evaluateModule(String source, int cpuBudgetMs) {
    // Use the bridge to establish the same native CPU/interrupt deadline, then
    // evaluate actual module grammar with QuickJS's public embedding API.
    evaluate('null', cpuBudgetMs: cpuBudgetMs);
    final native = source.toNativeUtf8();
    try {
      final failed = jsEvaluateModule(_handle, native, utf8.encode(source).length);
      evaluate('__cell.module(__moduleResult, $failed); delete globalThis.__moduleResult; null', cpuBudgetMs: cpuBudgetMs);
    } finally { malloc.free(native); }
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

  void resetContext() => traceSync('code_mode.cell.reset', () {
    if (_running) throw StateError('Cannot reset an executing cell');
    jsResetContext(_handle);
    _closeExit?.call(); _closeExit = null;
    _closeMedia?.call(); _closeMedia = null;
    _exited = false;
  }, category: 'code_mode', attributes: {'runtime.name': 'quickjs'}, includeErrorMessage: false);

  /// Consume only output produced since the preceding observation.
  Json takeOutput({int maxTokens = 10000}) => traceSync('code_mode.cell.output.render', () {
    final result = takeCollectedOutput();
    final rendered = renderCellContent(jsonObject(result['output']), maxTokens);
    return {
      'output': rendered.items.where((part) => part['type'] == 'input_text').map((part) => part['text']).toList(),
      'content': rendered.items,
      if (rendered.items.any((part) => part['type'] != 'input_text')) 'text_audio_tokens': rendered.textAudioTokens,
      if ((result['images'] as List).isNotEmpty) 'images': result['images'],
    };
  }, category: 'code_mode', includeErrorMessage: false);

  Json takeCollectedOutput() => traceSync('code_mode.cell.output.collect',
    () => jsonObject(evaluate('__cell.takeOutput()')), category: 'code_mode', includeErrorMessage: false);

  Future<Json> run(
    String source, {
    required HostTool tool,
    required CancellationToken cancellation,
    Json values = const {},
    List<Json> catalog = const [],
    Duration? timeout = const Duration(seconds: 60),
    int cpuBudgetMs = 1000,
    bool awaitPending = true,
    bool retainOutput = false,
    bool module = false,
    String? cellId,
    CodeCancellationToken? interrupt,
    void Function()? onYield,
    Future<void> Function(String)? onNotify,
  }) => traceAsync('code_mode.cell', () async {
    cancellation.throwIfCancelled();
    if (_running) throw StateError('Only one cell may run in a context');
    if (_closeExit != null) resetContext();
    if (source.length > 256 * 1024) {
      throw const FormatException('Cell source too large');
    }
    final maxOutputTokens = cellOutputTokens(source);
    // A borrowed task interrupt must never be signalled by normal cell cleanup:
    // doing so would cancel sibling yielded cells sharing the task's signal.
    final signal = interrupt ?? (cancellation is CodeCancellationToken ? cancellation : null);
    final localSignal = signal == null ? CodeCancellationToken() : null;
    final cell = localSignal ?? CancellationToken();
    final link = CancellationHook(cancellation, cell.cancel);
    final deadline = timeout == null ? null : Timer(timeout, () => cell.cancel(TimeoutException('JavaScript cell timed out', timeout)));
    _running = true;
    final pending = <int, Future<void>>{};
    final replies = <Json>[];
    final timers = <int, Timer>{};
    var wake = Completer<void>();
    void ready() { if (!wake.isCompleted) wake.complete(); }
    final clock = Stopwatch()..start();
    final timings = currentTrace == null ? null : <String, int>{};
    T measure<T>(String operation, T Function() action) {
      if (timings == null) return action();
      final watch = Stopwatch()..start();
      try { return action(); }
      finally {
        timings.update('$operation.duration_us', (value) => value + watch.elapsedMicroseconds,
          ifAbsent: () => watch.elapsedMicroseconds);
        timings.update('$operation.calls', (value) => value + 1, ifAbsent: () => 1);
      }
    }
    int budget() {
      cell.throwIfCancelled();
      signal?.throwIfCancelled();
      if (timeout == null) return cpuBudgetMs;
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        cell.cancel(TimeoutException('JavaScript cell timed out', timeout));
        cell.throwIfCancelled();
      }
      return cpuBudgetMs.clamp(1, remaining.inMilliseconds.clamp(1, cpuBudgetMs));
    }
    Object? evaluateCell(String source) =>
      measure('code.evaluate', () => evaluate(source, cpuBudgetMs: budget()));
    Json snapshot() => traceSync('code_mode.cell.output.collect', () {
      final result = jsonObject(evaluateCell(retainOutput ? '({values: __cell.values, writes: __cell.writes})'
        : '({output: __cell.output.collect(), images: __cell.images, values: __cell.values})'));
      final rendered = !retainOutput && module ? renderCellContent(jsonObject(result['output']), maxOutputTokens) : null;
      return {
        if (!retainOutput) 'output': rendered == null ? renderCellOutput(jsonObject(result['output']), maxOutputTokens)
          : rendered.items.where((part) => part['type'] == 'input_text').map((part) => part['text']).toList(),
        if (rendered != null) 'content': rendered.items,
        'values': result['values'],
        if (retainOutput) 'writes': result['writes'],
        if (!retainOutput && (result['images'] as List).isNotEmpty) 'images': result['images'],
      };
    }, category: 'code_mode', includeErrorMessage: false);
    jsSetInterrupt(_handle, Pointer.fromAddress(signal?.address ?? localSignal!.address), signal?.generation ?? localSignal!.generation);
    try {
      traceSync('code_mode.cell.init', () {
        evaluateCell(_bootstrap);
        _closeExit = jsInstallExit(_handle, () { _exited = true; });
        if (module) _closeMedia = jsInstallAudioMetadata(_handle, (url) { budget(); final value = audioMetadata(url); budget(); return value; });
        evaluateCell('ALL_TOOLS.push(...${jsonEncode(catalog)}); null');
        evaluateCell('__cell.configureTools($module); null');
        evaluateCell('__cell.values = ${jsonEncode(values)}; null');
      }, category: 'code_mode', attributes: {
        'code.catalog_count': catalog.length, 'code.values_count': values.length,
      }, includeErrorMessage: false);
      traceSync('code_mode.cell.start', () {
        if (module) { measure('code.module', () => _evaluateModule(source, budget())); }
        else { evaluateCell('__cell.start(${jsonEncode(source)}); null'); }
      }, category: 'code_mode', includeErrorMessage: false);
      while (true) {
        budget();
        while (replies.isNotEmpty) {
          evaluateCell(
            '__cell.resolve(${jsonEncode(replies.removeAt(0))}); null',
          );
        }
        final error = measure('code.pump', () => jsPump(_handle, 128, budget()));
        if (error != nullptr) _decode(error);
        final state = jsonObject(evaluateCell('__cell.poll()'));
        for (final timer in state['timers'] as List) {
          final id = timer['id'] as int;
          if (timer['delay'] == null) {
            timers.remove(id)?.cancel();
          } else {
            timers[id] = Timer(Duration(milliseconds: timer['delay'] as int), () {
              timers.remove(id);
              if (!cell.isCancelled) { replies.add({'timer': id}); ready(); }
            });
          }
        }
        for (final notice in state['notices'] as List) {
          await onNotify?.call(notice as String);
        }
        if (state['yielded'] == true) {
          traceInstant('code_mode.yield', category: 'code_mode');
          onYield?.call();
        }
        for (final raw in state['requests'] as List) {
          budget();
          final request = jsonObject(raw);
          final id = request['id'] as int;
          final operation = traceAsync<Object?>('code_mode.host_tool',
            () => tool(request['name'] as String, request['args'] ?? {}, cancellation: cell),
            category: 'code_mode', attributes: {'tool.name': request['name']},
            includeErrorMessage: false,
          );
          pending[id] = operation.then<void>(
            (value) {
              if (!cell.isCancelled) { replies.add({'id': id, 'ok': true, 'value': value}); ready(); }
            },
            onError: (Object error, StackTrace stack) {
              if (!cell.isCancelled) { replies.add({'id': id, 'ok': false, 'value': error.toString()}); ready(); }
            },
          );
          unawaited(pending[id]!.whenComplete(() => pending.remove(id)));
        }
        if (state['error'] != null) throw StateError(_describeCellError(state['error'] as String, source));
        if (state['done'] == true && (!awaitPending || pending.isEmpty && replies.isEmpty)) {
          return snapshot();
        }
        // Let cancellation and async host I/O run between bounded native calls.
        if (jsHasJobs(_handle) == 0 && replies.isEmpty) {
          await traceAsync('code_mode.cell.idle', () => wake.future.asCancellable(cell),
            category: 'code_mode', attributes: {
              'code.pending_host_calls': pending.length, 'code.pending_timers': timers.length,
            }, includeErrorMessage: false);
          wake = Completer<void>();
        } else {
          await cancellableDelay(Duration.zero, cell);
        }
      }
    } catch (_) {
      // Native execution may observe the atomic signal before Dart can service
      // the cancellation mailbox or deadline timer.
      budget();
      if (_exited) {
        jsClearExit(_handle);
        final state = jsonObject(evaluateCell('__cell.poll()'));
        for (final notice in state['notices'] as List) { await onNotify?.call(notice as String); }
        return snapshot();
      }
      rethrow;
    } finally {
      try {
        await traceAsync('code_mode.cell.cleanup', () async {
          deadline?.cancel();
          link.dispose();
          cell.cancel();
          for (final timer in timers.values) { timer.cancel(); }
          await Future.wait(pending.values.toList());
          replies.clear();
          jsSetInterrupt(_handle, nullptr, 0);
          localSignal?.close();
          _running = false;
        }, category: 'code_mode', includeErrorMessage: false);
      } finally {
        if (timings != null) traceInstant('code_mode.cell.metrics', category: 'code_mode', attributes: timings);
      }
    }
  }, category: 'code_mode', attributes: {
    'code.cell_id': ?cellId, 'code.source_length': source.length,
    'code.mode': module ? 'module' : 'script', 'runtime.name': 'quickjs',
    'code.cpu_budget_ms': cpuBudgetMs, 'code.await_pending': awaitPending,
    'code.retain_output': retainOutput,
    if (timeout != null) 'code.timeout_ms': timeout.inMilliseconds,
  }, includeErrorMessage: false);

  void close() => traceSync('code_mode.runtime.close', () {
    if (_handle != nullptr) {
      jsFree(_handle);
      _handle = nullptr;
      _closeExit?.call(); _closeExit = null;
      _closeMedia?.call(); _closeMedia = null;
    }
  }, category: 'code_mode', attributes: {'runtime.name': 'quickjs'}, includeErrorMessage: false);
}

String _describeCellError(String error, String source) {
  final frame = RegExp(r'\bexec_main\.mjs:(\d+):(\d+)').firstMatch(error);
  if (frame == null) return error;
  final lineNumber = int.parse(frame[1]!), columnNumber = int.parse(frame[2]!);
  final lines = source.split('\n');
  if (lineNumber < 1 || lineNumber > lines.length) return error;
  final line = lines[lineNumber - 1];
  final column = (columnNumber - 1).clamp(0, line.length);
  final start = (column - 80).clamp(0, line.length), end = (column + 120).clamp(0, line.length);
  final prefix = start == 0 ? '' : '…', suffix = end == line.length ? '' : '…';
  final indent = '${start == 0 ? '' : ' '}${line.substring(start, column).replaceAll(RegExp(r'[^\t]'), ' ')}';
  return '${error.trimRight()}\n\nexec_main.mjs:$lineNumber:$columnNumber\n'
    '$prefix${line.substring(start, end)}$suffix\n$indent^';
}

const _bootstrap = outputBootstrap + r'''
var ALL_TOOLS = [];
var __cell = (() => {
  // Match V8's useful JSON diagnostics while preserving native parsing,
  // reviver context/receivers, and exceptions raised by the reviver itself.
  const parseJson = JSON.parse, apply = Reflect.apply;
  JSON.parse = {parse(value, reviver) {
    let reviving = false;
    const revive = typeof reviver === "function" ? function(...args) {
      reviving = true;
      return apply(reviver, this, args);
    } : reviver;
    try { return parseJson(value, revive); }
    catch (cause) {
      if (!reviving && typeof value === "string" && cause instanceof SyntaxError) {
        const preview = value.length > 240 ? value.slice(0, 240) + "…" : value;
        cause.message += "\nJSON input: " + JSON.stringify(preview);
      }
      throw cause;
    }
  }}.parse;
  const pending = new Map();
  const requests = [];
  let output = __createOutput();
  let images = [];
  const timers = [], timeouts = new Map(), notices = [];
  let imageBytes = 0;
  let next = 1, nextTimeout = 1, done = false, error = null, yielded = false, exited = false;
  const exitSignal = {};
  const api = {
    values: {}, writes: {}, get output() { return output; }, get images() { return images; },
    configureTools(strict) {
      api.moduleMode = strict;
      if (strict) {
        globalThis.tools = Object.fromEntries(ALL_TOOLS.map(tool => [tool.name, args => hostCall(tool.name, args)]));
        globalThis.audio = audio; globalThis.generatedImage = generatedImage;
      }
    },
    start(source) {
      const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
      new AsyncFunction(source)().then(
        value => { if (value !== undefined) text(value); done = true; },
        cause => { if (!exited) error = String(cause) + (cause && cause.stack ? "\n" + cause.stack : ""); done = true; }
      );
    },
    module(result, failed) {
      if (failed) {
        if (!exited) error = String(result) + (result && result.stack ? "\n" + result.stack : ""); done = true;
      } else {
        Promise.resolve(result).then(() => { done = true; }, cause => {
          if (!exited) error = String(cause) + (cause && cause.stack ? "\n" + cause.stack : "");
          done = true;
        });
      }
    },
    poll() {
      const state = {done, error, requests: requests.splice(0), timers: timers.splice(0), notices: notices.splice(0), yielded};
      yielded = false;
      return state;
    },
    takeOutput() {
      const result = {output: output.collect(), images};
      output = __createOutput(); images = []; imageBytes = 0;
      return result;
    },
    resolve(reply) {
      if (reply.timer !== undefined) {
        const callback = timeouts.get(reply.timer);
        timeouts.delete(reply.timer);
        if (callback && !exited) callback();
        return;
      }
      const item = pending.get(reply.id);
      if (!item) throw new Error("Unknown host call");
      pending.delete(reply.id);
      if (reply.ok) item.resolve(reply.value);
      // Codex rejects host failures with text so allSettled/text preserve them.
      else item.reject(String(reply.value));
    }
  };
  function text(value) {
    if (exited) return;
    const content = serialize(value);
    output.push(content);
  }
  function serialize(value) {
    return value === null || ["string", "number", "boolean", "bigint", "undefined"].includes(typeof value)
      ? String(value) : JSON.stringify(value) ?? String(value);
  }
  function notify(value) {
    if (exited) return;
    const content = serialize(value);
    if (!content.trim()) throw new TypeError("notify expects non-empty text");
    notices.push(content);
  }
  function setTimeout(callback, delay = 0) {
    if (typeof callback !== "function") throw new TypeError("setTimeout expects a function callback");
    delay = Number(delay);
    const id = nextTimeout++;
    timeouts.set(id, callback);
    timers.push({id, delay: Number.isFinite(delay) && delay > 0 ? Math.min(Math.trunc(delay), 9007199254740991) : 0});
    return id;
  }
  function clearTimeout(id) {
    if (id == null) return;
    id = Math.trunc(Number(id));
    timeouts.delete(id);
    timers.push({id});
  }
  function yield_control() { if (!exited) yielded = true; }
  function exit() { exited = true; done = true; __nativeExit(); }
  function legacyImage(value, detail) {
    if (exited) return;
    const item = typeof value === "string" ? {image_url: value} : value;
    if (!item || typeof item !== "object") throw new Error("image expects an inline data URL or image content block");
    const source = item.image_url ?? item.data;
    if (typeof source !== "string") throw new Error("image requires inline image bytes");
    const match = /^data:(image\/(?:png|jpeg|gif|webp));base64,([\s\S]+)$/.exec(source);
    if (!match && (item.image_url !== undefined || source.startsWith("data:"))) {
      throw new Error("image requires a base64 image data URL; remote URLs are not supported");
    }
    const mime = match ? match[1] : item.mimeType ?? item.mime_type;
    const data = match ? match[2] : source;
    const hint = detail ?? item.detail ?? item._meta?.["codex/imageDetail"] ?? "high";
    if (!["auto", "low", "high", "original"].includes(hint)) throw new Error("Unsupported image detail");
    if (!["image/png", "image/jpeg", "image/gif", "image/webp"].includes(mime)) throw new Error("Unsupported image format");
    if (imageBytes + data.length > 32 * 1024 * 1024) throw new Error("Cell images exceed the 32 MiB output limit");
    imageBytes += data.length;
    images.push({type: "image", name: "Image", mime_type: mime, data, detail: hint});
  }
  function inlineUrl(value, kind) {
    const expected = kind + " expects a non-empty " + kind + " URL string, an object with " + kind + "_url" +
      (kind === "image" ? " and optional detail" : "") + ", or a raw MCP " + kind + " block";
    let source;
    if (typeof value === "string") source = value;
    else if (value && typeof value === "object" && !Array.isArray(value)) {
      const key = kind + "_url";
      if (value[key] !== undefined) {
        if (typeof value[key] !== "string") throw new TypeError(expected);
        source = value[key];
      } else {
        if (typeof value.type !== "string") throw new TypeError(expected);
        if (value.type !== kind) throw new TypeError(kind + " only accepts MCP " + kind + " blocks, got " + JSON.stringify(value.type));
        if (typeof value.data !== "string" || !value.data) throw new TypeError(kind + " expected MCP " + kind + " data");
        const mime = value.mimeType ?? value.mime_type;
        source = /^data:/i.test(value.data) ? value.data : "data:" + (typeof mime === "string" && mime ? mime : "application/octet-stream") + ";base64," + value.data;
      }
    }
    if (typeof source !== "string" || !source) throw new TypeError(expected);
    if (kind === "image" && /^https?:/i.test(source)) throw new TypeError("Tool call failed: remote image URLs are not supported in tool outputs. Pass a base64 data URI instead");
    if (!/^data:/i.test(source)) throw new TypeError("Tool call failed: invalid " + kind + " output. Pass a base64 data URI instead");
    return source;
  }
  function image(value, detail) {
    if (exited) return;
    if (!api.moduleMode) { legacyImage(value, detail); return; }
    const source = inlineUrl(value, "image");
    let embedded;
    if (value && typeof value === "object" && value.image_url !== undefined) embedded = value.detail;
    else {
      const hint = value?._meta?.["codex/imageDetail"];
      if (["auto", "low", "high", "original"].includes(hint)) embedded = hint;
    }
    for (const hint of [detail, embedded]) {
      if (hint != null && typeof hint !== "string") throw new TypeError("image detail must be a string when provided");
    }
    const hint = (detail ?? embedded ?? "high").toLowerCase();
    if (!["auto", "low", "high", "original"].includes(hint)) throw new TypeError("image detail must be one of: auto, low, high, original");
    output.push({type: "input_image", image_url: source, detail: hint});
  }
  function generatedImage(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new TypeError("generatedImage expects an image generation result object");
    if (value.output_hint !== undefined && typeof value.output_hint !== "string") throw new TypeError("generatedImage output_hint must be a string when provided");
    image(value);
    if (value.output_hint !== undefined) text(value.output_hint);
  }
  function audio(value) {
    if (exited) return;
    const source = inlineUrl(value, "audio"), metadata = __audioMetadata(source);
    if (metadata.error) throw new TypeError(metadata.error);
    if (metadata.omit) { text("Audio output omitted because the clip is shorter than 25 ms; use a longer clip."); return; }
    output.push({type: "input_audio", audio_url: source, _audio_tokens: metadata.tokens});
  }
  function store(key, value) {
    if (exited) return;
    const encoded = JSON.stringify(value);
    if (encoded === undefined) throw new Error("store requires a JSON value");
    key = String(key);
    const snapshot = JSON.parse(encoded);
    for (const target of [api.values, api.writes]) {
      Object.defineProperty(target, key, {value: snapshot, configurable: true, enumerable: true, writable: true});
    }
  }
  function load(key) { return Object.prototype.hasOwnProperty.call(api.values, String(key)) ? JSON.parse(JSON.stringify(api.values[String(key)])) : undefined; }
  function hostCall(name, args) {
    if (exited) throw exitSignal;
    if (pending.size >= 64) throw new Error("Too many outstanding host calls");
    const id = next++;
    requests.push({id, name, args: args ?? {}});
    return new Promise((resolve, reject) => { pending.set(id, {resolve, reject}); });
  }
  const tools = new Proxy({}, {get(_, name) { return args => hostCall(String(name), args); }});
  for (const name of ["console", "Atomics", "SharedArrayBuffer", "WebAssembly"]) delete globalThis[name];
  for (const [name, value] of Object.entries({text, image, store, load, tools, notify, setTimeout, clearTimeout, yield_control, exit})) {
    globalThis[name] = value;
  }
  return api;
})();
''';
