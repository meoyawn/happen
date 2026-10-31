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
