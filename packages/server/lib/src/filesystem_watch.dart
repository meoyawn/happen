// Codex fs/watch: connection-scoped IDs, direct paths, and a 200 ms debounce.
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';

sealed class _WatchState { const _WatchState(); }
final class _WatchStarting extends _WatchState { const _WatchStarting(); }
final class _WatchReady extends _WatchState { const _WatchReady(); }
final class _WatchFailed extends _WatchState {
  const _WatchFailed(this.error);
  final Object error;
}
final class _WatchClosing extends _WatchState { const _WatchClosing(); }
final class _WatchClosed extends _WatchState { const _WatchClosed(); }

_WatchState _transition(_WatchState current, _WatchState next) => switch ((current, next)) {
  (_WatchStarting(), _WatchReady() || _WatchFailed() || _WatchClosing()) => next,
  (_WatchReady(), _WatchFailed() || _WatchClosing()) => next,
  (_WatchFailed(), _WatchClosing()) => next,
  (_WatchClosing(), _WatchClosed()) => next,
  _ => throw StateError('Invalid filesystem watch transition'),
};

/// Only tokens and acknowledgements live here; the worker owns the OS watcher.
class FileSystemWatch {
  FileSystemWatch(Json params, CancellationToken lifetime, void Function(Json) emit) {
    _done = _run(params, lifetime, emit);
  }
  final _cancellation = CancellationToken();
  final _ready = Completer<Json>();
  _WatchState _state = const _WatchStarting();
  late final Future<void> _done;
  Future<void>? _closing;
  Future<Json> get ready => _ready.future;

  Future<void> _run(Json params, CancellationToken lifetime, void Function(Json) emit) async {
    try {
      await runIsolateEffect<void>(_watchEffect, params, timeout: null,
        cancellation: _cancellation.merge(lifetime), onEvent: (event) {
          if (_cancellation.isCancelled || lifetime.isCancelled) return;
          if (event['ready'] == true && _state is _WatchStarting) {
            _state = _transition(_state, const _WatchReady());
            _ready.complete({'path': event['path']});
          } else if (_state is _WatchReady) {
            emit({'method': 'fs/changed', 'params': event});
          }
        });
    } catch (error, stack) {
      if (_state is _WatchStarting || _state is _WatchReady) _state = _transition(_state, _WatchFailed(error));
      if (!_ready.isCompleted) _ready.completeError(error, stack);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _state = _transition(_state, const _WatchClosing());
    _cancellation.cancel();
    await _done;
    _state = _transition(_state, const _WatchClosed());
  }
}

Future<void> _watchEffect(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final path = params['path'] as String, watchId = params['watchId'] as String;
  final directory = await FileSystemEntity.type(path) == FileSystemEntityType.directory;
  cancellation.throwIfCancelled();
  final watched = directory ? path : p.dirname(path);
  final changed = <String>{}, failed = Completer<void>();
  Timer? debounce;
  void add(String candidate) {
    if (cancellation.isCancelled) return;
    final normalized = p.normalize(p.absolute(candidate));
    if (!directory && !p.equals(normalized, p.normalize(path))) return;
    changed.add(normalized);
    debounce ??= Timer(const Duration(milliseconds: 200), () {
      debounce = null;
      if (cancellation.isCancelled || changed.isEmpty) return;
      final paths = changed.toList()..sort();
      changed.clear();
      emit({'watchId': watchId, 'changedPaths': paths});
    });
  }
  // Watching the parent keeps file watches alive across rename-based saves and
  // also permits a file that does not exist yet, as Codex's watcher does.
  final subscription = Directory(watched).watch().listen((event) {
    add(event.path);
    if (event is FileSystemMoveEvent && event.destination != null) add(event.destination!);
  }, onError: (Object error, StackTrace stack) {
    if (!failed.isCompleted) failed.completeError(error, stack);
  }, onDone: () {
    if (!failed.isCompleted) failed.completeError(StateError('Filesystem watcher stopped'));
  });
  try {
    emit({'ready': true, 'path': path});
    await failed.future.asCancellable(cancellation);
  } finally {
    debounce?.cancel();
    await subscription.cancel();
  }
}
