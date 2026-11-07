import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:path/path.dart' as p;

/// Watches parent directories so editor renames do not detach the watch.
/// Periodic reconciliation also handles missing/recreated directories and
/// filesystems that drop notifications. ConfigReader reloads and validates data.
class ConfigWatcher with Cancellable {
  ConfigWatcher(
    Iterable<String> paths, {
    required this.onChange,
    required CancellationToken cancellation,
  }) : _paths = paths.map(p.absolute).map(p.normalize).toSet() {
    cancellation.throwIfCancelled();
    maybeAttach(cancellation);
    _attach();
    _schedule();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      _attach();
      _schedule();
    });
  }

  final Set<String> _paths;
  final void Function() onChange;
  final _directories = <String, StreamSubscription<FileSystemEvent>>{};
  Timer? _poll, _debounce;
  Future<void>? _closing;
  bool _closed = false;

  void updatePaths(Iterable<String> paths) {
    if (_closed) return;
    _paths
      ..clear()
      ..addAll(paths.map(p.absolute).map(p.normalize));
    final parents = _paths.map(p.dirname).toSet();
    for (final parent in _directories.keys.toList()) {
      if (!parents.contains(parent)) {
        unawaited(_directories.remove(parent)!.cancel());
      }
    }
    _attach();
  }

  void _schedule() {
    if (_closed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), onChange);
  }

  void _attach() {
    if (_closed || !FileSystemEntity.isWatchSupported) return;
    for (final parent in _paths.map(p.dirname).toSet()) {
      if (_directories.containsKey(parent)) continue;
      late StreamSubscription<FileSystemEvent> subscription;
      void lost() {
        if (identical(_directories[parent], subscription)) {
          _directories.remove(parent);
        }
        unawaited(subscription.cancel());
      }

      try {
        subscription = Directory(parent).watch().listen(
          (event) {
            // Native events may resolve a symlink in the watched directory
            // (notably /var -> /private/var on macOS). Compare direct filenames.
            if (_paths.where((path) => p.dirname(path) == parent).any((path) =>
                p.basename(path) == p.basename(event.path) ||
                event is FileSystemMoveEvent &&
                    event.destination != null &&
                    p.basename(path) == p.basename(event.destination!))) {
              _schedule();
            }
          },
          onError: (Object _) => lost(),
          onDone: lost,
          cancelOnError: true,
        );
        _directories[parent] = subscription;
      } on FileSystemException {
        // The parent may not exist yet. The next poll retries attachment.
      }
    }
  }

  @override
  void onCancel(Exception cancelException) {
    super.onCancel(cancelException);
    unawaited(close());
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    detach();
    _poll?.cancel();
    _debounce?.cancel();
    final subscriptions = _directories.values.toList();
    _directories.clear();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }
}
