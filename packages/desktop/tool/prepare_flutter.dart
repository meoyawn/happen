import 'dart:io';

// Flutter 3.47.9 still leaves MouseTracker's debug guard set when a hit test or
// hover callback throws. Repair the owning SDK, not application input/state.
// Match the whole method so an SDK upgrade cannot silently receive a bad patch.
const _original = '''  void _deviceUpdatePhase(VoidCallback task) {
    assert(!_debugDuringDeviceUpdate);
    assert(() {
      _debugDuringDeviceUpdate = true;
      return true;
    }());
    task();
    assert(() {
      _debugDuringDeviceUpdate = false;
      return true;
    }());
  }''';

const _fixed = '''  void _deviceUpdatePhase(VoidCallback task) {
    assert(!_debugDuringDeviceUpdate);
    assert(() {
      _debugDuringDeviceUpdate = true;
      return true;
    }());
    try {
      task();
    } finally {
      // A failed hit test or hover callback must not disable future updates.
      assert(() {
        _debugDuringDeviceUpdate = false;
        return true;
      }());
    }
  }''';

void main(List<String> args) {
  try {
    if (args.length > 1 || args.isNotEmpty && !['--check', '--revert'].contains(args.single)) {
      throw ArgumentError('Usage: dart packages/desktop/tool/prepare_flutter.dart [--check|--revert]');
    }
    final sdk = _flutterSdk();
    final file = File.fromUri(sdk.uri.resolve('packages/flutter/lib/src/rendering/mouse_tracker.dart'));
    final source = file.readAsStringSync();
    final before = args.contains('--revert') ? _fixed : _original;
    final after = args.contains('--revert') ? _original : _fixed;
    if (after.allMatches(source).length == 1 && !source.contains(before)) {
      stdout.writeln('Flutter mouse tracker ${args.contains('--revert') ? 'unpatched' : 'ready'}: ${sdk.path}');
      return;
    }
    if (before.allMatches(source).length != 1 || source.contains(after)) {
      throw StateError('Flutter MouseTracker changed in ${sdk.path}. Review the SDK fix and run '
        'packages/desktop/test/mouse_tracker_test.dart before updating this patch. No files changed.');
    }
    if (args.contains('--check')) {
      throw StateError('Flutter mouse tracker is vulnerable. Run dart packages/desktop/tool/prepare_flutter.dart.');
    }
    file.writeAsStringSync(source.replaceFirst(before, after), flush: true);
    stdout.writeln('${args.contains('--revert') ? 'Reverted' : 'Applied'} Flutter mouse tracker cleanup: ${sdk.path}');
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

Directory _flutterSdk() {
  final name = Platform.isWindows ? 'flutter.bat' : 'flutter';
  for (final path in (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
    if (path.isEmpty) continue;
    final executable = File('$path${Platform.pathSeparator}$name');
    if (!executable.existsSync()) continue;
    return File(executable.resolveSymbolicLinksSync()).parent.parent;
  }
  throw StateError('Flutter is not on PATH.');
}
