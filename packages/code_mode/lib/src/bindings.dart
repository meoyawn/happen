import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

// These calls can execute arbitrary JS; they must remain non-leaf FFI calls.
@Native<Pointer<Void> Function(Int64)>(symbol: 'embedded_js_new')
external Pointer<Void> jsNew(int memoryLimit);

@Native<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Int64)>(
  symbol: 'embedded_js_eval',
)
external Pointer<Utf8> jsEval(
  Pointer<Void> runtime,
  Pointer<Utf8> source,
  int budgetMs,
);

@Native<Pointer<Utf8> Function(Pointer<Void>, Int32, Int64)>(
  symbol: 'embedded_js_pump',
)
external Pointer<Utf8> jsPump(Pointer<Void> runtime, int jobs, int budgetMs);

@Native<Void Function(Pointer<Void>)>(symbol: 'embedded_js_reset_context')
external void jsResetContext(Pointer<Void> runtime);

@Native<Void Function(Pointer<Void>)>(symbol: 'embedded_js_free')
external void jsFree(Pointer<Void> runtime);

@Native<Void Function(Pointer<Utf8>)>(symbol: 'embedded_js_string_free')
external void jsStringFree(Pointer<Utf8> value);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'embedded_js_has_jobs')
external int jsHasJobs(Pointer<Void> runtime);

@Native<Uint64 Function()>(symbol: 'embedded_js_thread_id')
external int nativeThreadId();

@Native<Pointer<Void> Function()>(symbol: 'embedded_js_interrupt_new')
external Pointer<Void> jsInterruptNew();

@Native<Void Function(Pointer<Void>)>(symbol: 'embedded_js_interrupt_signal')
external void jsInterruptSignal(Pointer<Void> interrupt);

@Native<Uint64 Function(Pointer<Void>)>(symbol: 'embedded_js_interrupt_generation')
external int jsInterruptGeneration(Pointer<Void> interrupt);

@Native<Void Function(Pointer<Void>)>(symbol: 'embedded_js_interrupt_free')
external void jsInterruptFree(Pointer<Void> interrupt);

@Native<Void Function(Pointer<Void>, Pointer<Void>, Uint64)>(symbol: 'embedded_js_set_interrupt')
external void jsSetInterrupt(Pointer<Void> runtime, Pointer<Void> interrupt, int generation);

// The vendored 64-bit QuickJS ABI. Module evaluation returns a JSValue (not
// JSON); transfer it into the cell's global before servicing its promise.
final class _Engine extends Struct {
  external Pointer<Void> runtime;
  external Pointer<Void> context;
}

final class _ValuePayload extends Union {
  @Uint64() external int bits;
  external Pointer<Void> pointer;
}

final class _Value extends Struct {
  external _ValuePayload payload;
  @Int64() external int tag;
}

@Native<_Value Function(Pointer<Void>, Pointer<Utf8>, Size, Pointer<Utf8>, Int32)>(symbol: 'JS_Eval')
external _Value _eval(Pointer<Void> context, Pointer<Utf8> source, int length, Pointer<Utf8> filename, int flags);
@Native<_Value Function(Pointer<Void>)>(symbol: 'JS_GetGlobalObject')
external _Value _global(Pointer<Void> context);
@Native<_Value Function(Pointer<Void>)>(symbol: 'JS_GetException')
external _Value _exception(Pointer<Void> context);
@Native<Int32 Function(Pointer<Void>, _Value, Pointer<Utf8>, _Value)>(symbol: 'JS_SetPropertyStr')
external int _setProperty(Pointer<Void> context, _Value target, Pointer<Utf8> key, _Value value);
@Native<Void Function(Pointer<Void>, _Value)>(symbol: '__JS_FreeValue')
external void _freeValue(Pointer<Void> context, _Value value);

typedef _Function = _Value Function(Pointer<Void>, _Value, Int32, Pointer<_Value>);
@Native<_Value Function(Pointer<Void>, Pointer<NativeFunction<_Function>>, Pointer<Utf8>, Int32, Int32, Int32)>(symbol: 'JS_NewCFunction2')
external _Value _function(Pointer<Void> context, Pointer<NativeFunction<_Function>> callback, Pointer<Utf8> name, int length, int kind, int magic);
@Native<_Value Function(Pointer<Void>, Pointer<Utf8>, Size)>(symbol: 'JS_NewStringLen')
external _Value _string(Pointer<Void> context, Pointer<Utf8> text, int length);
@Native<_Value Function(Pointer<Void>, _Value)>(symbol: 'JS_Throw')
external _Value _throw(Pointer<Void> context, _Value value);
@Native<Void Function(Pointer<Void>, Int32)>(symbol: 'JS_SetUncatchableException')
external void _uncatchable(Pointer<Void> context, int enabled);
@Native<Pointer<Utf8> Function(Pointer<Void>, Pointer<Size>, _Value, Int32)>(symbol: 'JS_ToCStringLen2')
external Pointer<Utf8> _toString(Pointer<Void> context, Pointer<Size> length, _Value value, int cesu8);
@Native<Void Function(Pointer<Void>, Pointer<Utf8>)>(symbol: 'JS_FreeCString')
external void _freeString(Pointer<Void> context, Pointer<Utf8> value);
@Native<_Value Function(Pointer<Void>, Pointer<Utf8>, Size, Pointer<Utf8>)>(symbol: 'JS_ParseJSON')
external _Value _parseJson(Pointer<Void> context, Pointer<Utf8> source, int length, Pointer<Utf8> filename);

void _release(Pointer<Void> context, _Value value) {
  if (value.tag >= 0) return;
  final count = Pointer<Int32>.fromAddress(value.payload.pointer.address - sizeOf<Uint32>());
  count.value--;
  if (count.value <= 0) _freeValue(context, value);
}

/// The callable must outlive its JS context, not merely a run() observation.
/// A native uncatchable exception gives exit() termination semantics, including
/// through finally blocks, without pretending a catchable JS sentinel can exit.
void Function() jsInstallExit(Pointer<Void> runtime, void Function() onExit) {
  if (sizeOf<IntPtr>() != 8) throw UnsupportedError('QuickJS native helpers require the 64-bit value ABI');
  final context = runtime.cast<_Engine>().ref.context;
  final callable = NativeCallable<_Function>.isolateLocal((Pointer<Void> context, _Value receiver, int argc, Pointer<_Value> argv) {
    onExit();
    final text = 'exec exit'.toNativeUtf8();
    try {
      final result = _throw(context, _string(context, text, 9));
      _uncatchable(context, 1);
      return result;
    } finally { malloc.free(text); }
  });
  final name = '__nativeExit'.toNativeUtf8();
  final global = _global(context);
  try {
    final function = _function(context, callable.nativeFunction, name, 0, 0, 0);
    if (_setProperty(context, global, name, function) < 0) throw StateError('Could not install exit');
    return callable.close;
  } catch (_) {
    callable.close();
    rethrow;
  } finally { _release(context, global); malloc.free(name); }
}

void jsClearExit(Pointer<Void> runtime) => _uncatchable(runtime.cast<_Engine>().ref.context, 0);

/// Synchronous metadata only: no I/O or audio playback occurs in this callback.
void Function() jsInstallAudioMetadata(Pointer<Void> runtime, Map<String, Object?> Function(String) metadata) {
  final context = runtime.cast<_Engine>().ref.context;
  final callable = NativeCallable<_Function>.isolateLocal((Pointer<Void> context, _Value receiver, int argc, Pointer<_Value> argv) {
    final length = calloc<Size>();
    Pointer<Utf8> source = nullptr;
    try {
      Map<String, Object?> value;
      if (argc == 0) { value = {'error': 'audio expects an inline URL'}; }
      else {
        source = _toString(context, length, argv[0], 0);
        if (source == nullptr) return _throw(context, _exception(context));
        try { value = metadata(utf8.decode(source.cast<Uint8>().asTypedList(length.value), allowMalformed: true)); }
        catch (error) { value = {'error': error.toString()}; }
      }
      final json = jsonEncode(value).toNativeUtf8(), filename = '<audio-metadata>'.toNativeUtf8();
      try { return _parseJson(context, json, json.length, filename); }
      finally { malloc.free(json); malloc.free(filename); }
    } finally { if (source != nullptr) _freeString(context, source); calloc.free(length); }
  });
  final name = '__audioMetadata'.toNativeUtf8(), global = _global(context);
  try {
    if (_setProperty(context, global, name, _function(context, callable.nativeFunction, name, 1, 0, 0)) < 0) {
      throw StateError('Could not install audio metadata');
    }
    return callable.close;
  } catch (_) { callable.close(); rethrow; }
  finally { _release(context, global); malloc.free(name); }
}

/// Returns whether compilation/evaluation threw. JS_SetPropertyStr consumes
/// its value. Release our global reference using quickjs.h's JS_FreeValue
/// inline operation (the refcount header is immediately before the payload).
bool jsEvaluateModule(Pointer<Void> runtime, Pointer<Utf8> source, int length) {
  if (sizeOf<IntPtr>() != 8) throw UnsupportedError('QuickJS modules require the 64-bit value ABI');
  final context = runtime.cast<_Engine>().ref.context;
  final filename = 'exec_main.mjs'.toNativeUtf8(), key = '__moduleResult'.toNativeUtf8();
  try {
    var value = _eval(context, source, length, filename, 1); // JS_EVAL_TYPE_MODULE
    final failed = value.tag == 6; // JS_TAG_EXCEPTION
    if (failed) value = _exception(context);
    final global = _global(context);
    try {
      if (_setProperty(context, global, key, value) < 0) throw StateError('Could not retain the module result');
    } finally {
      _release(context, global);
    }
    if (failed) _uncatchable(context, 0);
    return failed;
  } finally { malloc.free(filename); malloc.free(key); }
}
