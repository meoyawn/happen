import 'dart:ffi';

import 'package:protocol/protocol.dart';

import 'bindings.dart';

/// Only this atomic signal crosses isolates; the interpreter remains single-owner.
/// Its owner must await the interpreter's shutdown before freeing it.
class CodeInterrupt {
  CodeInterrupt() : _handle = jsInterruptNew() {
    if (_handle == nullptr) throw StateError('Could not allocate code interrupt');
  }
  CodeInterrupt._shared(int address) : _handle = Pointer.fromAddress(address) {
    if (address == 0) throw ArgumentError.value(address, 'address', 'Interrupt must be open');
  }
  Pointer<Void> _handle;
  Pointer<Void> get _open {
    if (_handle == nullptr) throw StateError('Code interrupt is closed');
    return _handle;
  }
  int get address => _open.address;
  int get generation => jsInterruptGeneration(_open);
  void interrupt() => jsInterruptSignal(_open);
  void close() {
    if (_handle == nullptr) return;
    jsInterruptFree(_handle);
    _handle = nullptr;
  }
}

/// A Dart token with a native interrupt, so another isolate can stop CPU-bound JS
/// while this isolate's event loop is inside FFI.
class CodeCancellationToken extends CancellationToken {
  CodeCancellationToken() : _signal = CodeInterrupt(), _ownsSignal = true {
    generation = _signal.generation;
  }
  CodeCancellationToken.shared(int address, {int? generation})
      : _signal = CodeInterrupt._shared(address), _ownsSignal = false {
    this.generation = generation ?? _signal.generation;
  }
  final CodeInterrupt _signal;
  final bool _ownsSignal;
  late final int generation;
  int get address => _signal.address;
  bool get interrupted => _signal.generation != generation;

  @override
  void throwIfCancelled() {
    super.throwIfCancelled();
    if (interrupted) cancel();
    super.throwIfCancelled();
  }

  @override
  void cancel([Exception? exception]) {
    if (isCancelled) return;
    _signal.interrupt();
    super.cancel(exception);
  }

  void close() {
    cancel();
    if (_ownsSignal) _signal.close();
  }
}
