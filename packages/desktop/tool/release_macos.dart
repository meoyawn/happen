import 'dart:io';

import 'run_flutter.dart' as launcher;

final _release = Directory('${launcher.desktopRoot.path}/build/macos/Build/Products/Release/${launcher.app}');
const _register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';

void _run(String command, List<String> arguments) {
  final result = Process.runSync(command, arguments, workingDirectory: launcher.desktopRoot.path);
  if (result.exitCode != 0) throw ProcessException(command, arguments, '${result.stderr}', result.exitCode);
}

void _verify(Directory bundle) {
  final info = launcher.bundleInfo(bundle);
  for (final relative in ['MacOS/${info['CFBundleExecutable']}', 'Frameworks/App.framework/App',
    'Frameworks/FlutterMacOS.framework/FlutterMacOS', 'Frameworks/sqlite3.framework/sqlite3',
    'Frameworks/code_mode.framework/code_mode', 'Resources/AppIcon.icns']) {
    if (!File('${bundle.path}/Contents/$relative').existsSync()) throw StateError('Incomplete release bundle: missing $relative');
  }
  _run('/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle.path]);
}

List<int> _releasePids(Directory bundle) {
  final executable = '${bundle.path}/Contents/MacOS/${launcher.bundleInfo(bundle)['CFBundleExecutable']}';
  return [for (final (pid, command) in launcher.processes('pid=,comm=')) if (command == executable) pid];
}

void _requireStopped(Directory bundle) {
  final pids = _releasePids(bundle);
  if (pids.isNotEmpty) throw StateError('Release still running as PID(s) $pids; no bundle was replaced.');
}

void _stopRelease(Directory bundle, List<int> pids) {
  stdout.writeln('Stopping release PID(s): $pids');
  for (final pid in pids) {
    // Recheck the executable path before signalling a possibly reused PID.
    if (_releasePids(bundle).contains(pid)) Process.killPid(pid, ProcessSignal.sigterm);
  }
  final elapsed = Stopwatch()..start();
  while (_releasePids(bundle).isNotEmpty) {
    if (elapsed.elapsed >= const Duration(seconds: 15)) _requireStopped(bundle);
    sleep(const Duration(milliseconds: 100));
  }
  stdout.writeln('Release app process exited.');
}

void _install(Directory applications) {
  _verify(_release);
  applications.createSync(recursive: true);
  applications = Directory(applications.resolveSymbolicLinksSync());
  final destination = Directory('${applications.path}/${launcher.app}');
  if (destination.path == _release.path) throw StateError('The installation destination must differ from the build output');
  if (FileSystemEntity.isLinkSync(destination.path)) throw StateError('Refusing to replace a symlink: ${destination.path}');
  final temporary = applications.createTempSync('.happen-install-');
  final staged = Directory('${temporary.path}/${launcher.app}'), previous = Directory('${temporary.path}/previous.app');
  var succeeded = false;
  try {
    _run('/usr/bin/ditto', [_release.path, staged.path]);
    _verify(staged);
    final lock = launcher.launchLock('${launcher.runDirectory.path}/launch.lock');
    try {
      if (launcher.appPids('release').length > 1 || launcher.flutterPids('release').length > 1) {
        throw StateError('Multiple release app/supervisor processes exist; refusing to reinstall.');
      }
      if (destination.existsSync()) {
        final pids = _releasePids(destination);
        if (pids.isNotEmpty) _stopRelease(destination, pids);
        _requireStopped(destination);
        destination.renameSync(previous.path);
      }
      try {
        staged.renameSync(destination.path);
        _verify(destination);
      } catch (_) {
        if (destination.existsSync()) destination.renameSync(staged.path);
        if (previous.existsSync()) previous.renameSync(destination.path);
        rethrow;
      }
    } finally { launcher.closeLaunchLock(lock); }
    succeeded = true;
    final result = Process.runSync(_register, ['-f', destination.path]);
    if (result.exitCode != 0) stdout.writeln('Installed successfully; Launch Services registration could not be refreshed.');
    stdout.writeln('Installed release: ${destination.path}');
  } finally {
    if (succeeded || !previous.existsSync()) { temporary.deleteSync(recursive: true); }
    else { stderr.writeln('Previous installation retained at ${previous.path}'); }
  }
}

void main(List<String> arguments) {
  if (!Platform.isMacOS) throw UnsupportedError('The release installer targets macOS');
  launcher.removeMoonEnvironment(arguments);
  var applications = '/Applications';
  if (arguments.length == 2 && arguments.first == '--applications-dir') {
    applications = arguments[1];
  } else if (arguments.length == 1 && arguments.first.startsWith('--applications-dir=')) {
    applications = arguments.first.substring('--applications-dir='.length);
  } else if (arguments.isNotEmpty) {
    stderr.writeln('Usage: release_macos.dart [--applications-dir PATH]');
    exitCode = arguments.length == 1 && ['--help', '-h'].contains(arguments.single) ? 0 : 2;
    return;
  }
  if (applications == '~' || applications.startsWith('~/')) {
    applications = '${Platform.environment['HOME']}${applications.substring(1)}';
  }
  launcher.runDirectory.createSync(recursive: true);
  final lock = launcher.launchLock('${launcher.runDirectory.path}/release-reinstall.lock');
  try { _install(Directory(applications).absolute); }
  finally { launcher.closeLaunchLock(lock); }
}
