import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:server/server.dart';

/// One desktop-owned assertion for its embedded server, including hidden tasks.
class LocalTaskSleepInhibitor {
  LocalTaskSleepInhibitor(AgentServer server, {required this.onError}) {
    _activity = server.activeTaskCounts.listen(_update, onDone: () => unawaited(close()));
    _update(server.activeTaskCount);
  }

  final void Function(Object) onError;
  late final StreamSubscription<int> _activity;
  bool _required = false, _closed = false, _failed = false;
  int? _assertion;
  Future<void>? _transition, _closing;

  void _update(int count) {
    if (_closed || !Platform.isMacOS || _required == (count > 0)) return;
    _required = count > 0;
    _failed = false;
    unawaited(_schedule());
  }

  Future<void> _schedule() => _transition ??= Future<void>.microtask(_reconcile).whenComplete(() {
    _transition = null;
    if (!_failed && _required != (_assertion != null)) unawaited(_schedule());
  });

  Future<void> _reconcile() async {
    while (_required != (_assertion != null)) {
      try {
        final id = _assertion;
        if (id == null) {
          _assertion = await Isolate.run(_createAssertion);
        } else {
          await _releaseInWorker(id);
          _assertion = null;
        }
      } catch (error) {
        // Keep a failed-release ID so a later transition cannot create a duplicate.
        _failed = true;
        onError(error);
        return;
      }
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _required = false;
    await _activity.cancel();
    _failed = false;
    // Drain an in-flight native create, then release its ID before closing.
    await _schedule();
  }
}

// Only primitive values cross workers. Synchronous power IPC never blocks UI.
Future<void> _releaseInWorker(int id) => Isolate.run(() => _releaseAssertion(id));

final _io = DynamicLibrary.open('/System/Library/Frameworks/IOKit.framework/IOKit');
final _cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
final _string = _cf.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32), Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)>('CFStringCreateWithCString');
final _releaseString = _cf.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');
final _create = _io.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>)>('IOPMAssertionCreateWithName');
final _release = _io.lookupFunction<Int32 Function(Uint32), int Function(int)>('IOPMAssertionRelease');

Pointer<Void> _newString(String value, Arena arena) {
  final result = _string(nullptr, value.toNativeUtf8(allocator: arena), 0x08000100);
  if (result == nullptr) throw StateError('Could not allocate sleep assertion name');
  arena.onReleaseAll(() => _releaseString(result));
  return result;
}

int _createAssertion() => using((arena) {
  // Prevent idle system sleep on AC and battery, while allowing display sleep.
  final type = _newString('PreventUserIdleSystemSleep', arena);
  final name = _newString('Happen / Running local tasks', arena);
  final result = arena<Uint32>();
  final status = _create(type, 255, name, result);
  if (status != 0 || result.value == 0) throw StateError('Could not prevent idle sleep for local tasks ($status)');
  return result.value;
});

void _releaseAssertion(int id) {
  final status = _release(id);
  if (status != 0) throw StateError('Could not release local task sleep assertion ($status)');
}
