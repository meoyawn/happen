import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:protocol/protocol.dart';

final desktopRoot = File.fromUri(Platform.script).absolute.parent.parent;
final runDirectory = Directory('${desktopRoot.parent.parent.path}/.local/run');
final _appInfo = _appConfiguration(desktopRoot.path);
final app = '${_appInfo['PRODUCT_NAME']!}.app', bundleId = _appInfo['PRODUCT_BUNDLE_IDENTIFIER']!;
final _libc = DynamicLibrary.process();
final _open = _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
  int Function(Pointer<Utf8>, int, int)>('open');
final _flock = _libc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('flock');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _errno = _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__error');
final _execve = _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>),
  int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>)>('execve');

/// Replace the process to preserve its PID, terminal, signals and exit status.
Never exec(String executable, List<String> arguments, Map<String, String> environment) {
  using((arena) {
    Pointer<Pointer<Utf8>> strings(List<String> values) {
      final pointers = arena<Pointer<Utf8>>(values.length + 1);
      for (var index = 0; index < values.length; index++) {
        pointers[index] = values[index].toNativeUtf8(allocator: arena);
      }
      pointers[values.length] = nullptr;
      return pointers;
    }
    _execve(executable.toNativeUtf8(allocator: arena), strings([executable, ...arguments]),
      strings(environment.entries.map((entry) => '${entry.key}=${entry.value}').toList()));
    throw ProcessException(executable, arguments, 'execve failed', _errno().value);
  });
}

/// Moon's task context must not become the environment of the app or its tools.
void removeMoonEnvironment(List<String> arguments) {
  final environment = Map<String, String>.of(Platform.environment)
    ..removeWhere((key, _) => key.startsWith('MOON_'));
  if (environment.length != Platform.environment.length) {
    exec(Platform.resolvedExecutable, [...Platform.executableArguments, Platform.script.toFilePath(), ...arguments], environment);
  }
}

/// Use flock so startup also serializes with other checkouts' launch tooling.
/// O_CLOEXEC releases the lock only once Flutter's entrypoint is discoverable.
int launchLock(String path) {
  final descriptor = using((arena) => _open(path.toNativeUtf8(allocator: arena), 0x2 | 0x200 | 0x1000000, 0x180));
  if (descriptor < 0) throw FileSystemException('Could not open launch lock', path, OSError('open failed', _errno().value));
  if (_flock(descriptor, 2) != 0) {
    final error = _errno().value;
    _close(descriptor);
    throw FileSystemException('Could not acquire launch lock', path, OSError('flock failed', error));
  }
  return descriptor;
}

void closeLaunchLock(int descriptor) { _close(descriptor); }

List<(int, String)> processes(String columns) {
  final result = Process.runSync('/bin/ps', ['-axo', columns]);
  if (result.exitCode != 0) throw ProcessException('/bin/ps', ['-axo', columns], '${result.stderr}', result.exitCode);
  return [
    for (final line in (result.stdout as String).split('\n'))
      if (RegExp(r'^\s*(\d+)\s+(.+)$').firstMatch(line) case final match?)
        (int.parse(match.group(1)!), match.group(2)!),
  ];
}

List<int> appPids([String? mode]) {
  final name = app.substring(0, app.length - 4), suffix = '/$app/Contents/MacOS/${app.substring(0, app.length - 4)}';
  final debug = '${desktopRoot.path}/build/macos/Build/Products/Debug$suffix';
  return [
    for (final (pid, command) in processes('pid=,comm='))
      if (command.endsWith(suffix) && (mode == null || mode == 'debug' && command == debug || mode == 'release' &&
          !['Debug', 'Profile'].any((configuration) => command.endsWith('/Build/Products/$configuration/$app/Contents/MacOS/$name')))) pid,
  ];
}

Map<String, String> _appConfiguration(String directory) {
  final values = <String, String>{};
  for (final line in File('$directory/macos/Runner/Configs/AppInfo.xcconfig').readAsLinesSync()) {
    final separator = line.indexOf('=');
    if (separator >= 0) values[line.substring(0, separator).trim()] = line.substring(separator + 1).trim();
  }
  return values;
}

bool _isHappenCheckout(String path) {
  for (final directory in [path, '$path/packages/desktop']) {
    try {
      final values = _appConfiguration(directory);
      if (values['PRODUCT_NAME'] == app.substring(0, app.length - 4) && values['PRODUCT_BUNDLE_IDENTIFIER'] == bundleId) return true;
    } on FileSystemException { continue; }
  }
  return false;
}

List<int> flutterPids([String? mode]) {
  final found = <int>[];
  for (final (pid, command) in processes('pid=,command=')) {
    // ps does not quote paths; matching the entrypoint suffix also handles
    // spaces and apostrophes in SDK paths without interpreting them as a shell.
    final entry = RegExp(r'(?:^|/)(?:flutter|flutter_tools\.snapshot|flutter_tools\.dart)(?=\s|$)').firstMatch(command);
    if (entry == null) continue;
    final arguments = command.substring(entry.end).trim().split(RegExp(r'\s+'));
    if (!arguments.contains('run')) continue;
    final selected = ['release', 'profile'].firstWhere((value) => arguments.contains('--$value'), orElse: () => 'debug');
    if (mode != null && selected != mode) continue;
    final cwd = Process.runSync('/usr/sbin/lsof', ['-a', '-p', '$pid', '-d', 'cwd', '-Fn']);
    final directories = (cwd.stdout as String).split('\n').where((line) => line.startsWith('n')).map((line) => line.substring(1));
    if (directories.any((directory) => directory == desktopRoot.path || directory == desktopRoot.parent.parent.path ||
        mode == null && _isHappenCheckout(directory))) found.add(pid);
  }
  return found;
}

Map<String, dynamic> bundleInfo(Directory bundle) {
  final result = Process.runSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '${bundle.path}/Contents/Info.plist']);
  if (result.exitCode != 0) throw StateError('Could not read bundle identity: ${bundle.path}: ${result.stderr}');
  final info = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  if (info['CFBundleIdentifier'] != bundleId || info['CFBundleExecutable'] != app.substring(0, app.length - 4)) {
    throw StateError('Refusing a bundle with a different application identity: ${bundle.path}');
  }
  return info;
}

Future<void> main(List<String> arguments) async {
  if (!Platform.isMacOS) throw UnsupportedError('The desktop launcher targets macOS');
  removeMoonEnvironment(arguments);
  if (arguments.any((argument) => argument != '--status')) {
    stderr.writeln('Usage: run_flutter.dart [--status]');
    exitCode = arguments.length == 1 && ['--help', '-h'].contains(arguments.single) ? 0 : 2;
    return;
  }
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  try { await _launch(arguments.contains('--status'), cancellation); }
  on CancelledException { exitCode = 130; }
  finally {
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<void> _resolveDevelopmentPackages(Directory sdk, Map<String, String> environment,
    CancellationToken cancellation) async {
  final packageFile = File('${desktopRoot.parent.parent.path}/.dart_tool/package_config.json');
  if (packageFile.existsSync()) {
    final config = jsonObject(jsonDecode(packageFile.readAsStringSync()));
    final framework = (config['packages'] as List).map(jsonObject)
      .where((package) => package['name'] == 'flutter').firstOrNull;
    if (framework != null) {
      final resolved = Directory.fromUri(packageFile.uri.resolve(framework['rootUri'] as String));
      if (resolved.existsSync() && resolved.resolveSymbolicLinksSync() ==
          Directory('${sdk.path}/packages/flutter').resolveSymbolicLinksSync()) return;
    }
  }
  cancellation.throwIfCancelled();
  final executable = '${sdk.path}/bin/flutter';
  final process = await Process.start(executable, ['pub', 'get'], workingDirectory: desktopRoot.parent.parent.path,
    environment: environment, includeParentEnvironment: false, mode: ProcessStartMode.inheritStdio);
  final hook = CancellationHook(cancellation, () => process.kill(ProcessSignal.sigterm));
  try {
    final code = await process.exitCode.asCancellable(cancellation);
    if (code != 0) throw ProcessException(executable, ['pub', 'get'], 'Development package resolution failed', code);
  } finally { hook.dispose(); }
}

Future<void> _launch(bool status, CancellationToken cancellation) async {
  runDirectory.createSync(recursive: true);
  final uid = _libc.lookupFunction<Uint32 Function(), int Function()>('getuid')();
  final shared = launchLock('${Directory.systemTemp.path}/$bundleId.$uid.$app.launch.lock');
  List<int> apps, supervisors;
  try {
    final local = launchLock('${runDirectory.path}/launch.lock');
    try {
      apps = appPids(); supervisors = flutterPids();
      if (apps.length > 1 || supervisors.length > 1) {
        stdout.writeln(jsonEncode({'error': 'Multiple existing instances; stop extras before continuing',
          'mode': 'debug', 'app_pids': apps, 'flutter_pids': supervisors}));
        exitCode = 2;
        return;
      }
      final sdk = Directory('${desktopRoot.parent.parent.path}/third_party/flutter');
      final flutter = File('${sdk.path}/bin/flutter');
      final environment = Map<String, String>.of(Platform.environment)..addAll({
        'FLUTTER_ROOT': sdk.path, 'PATH': '${sdk.path}/bin:${Platform.environment['PATH'] ?? ''}',
      });
      if (!status) {
        if (!flutter.existsSync()) throw StateError('Initialize third_party/flutter before running dev');
        await _resolveDevelopmentPackages(sdk, environment, cancellation);
      }
      if (status || apps.isNotEmpty || supervisors.isNotEmpty) {
        final value = <String, dynamic>{'mode': 'debug', 'reused': !status && (apps.isNotEmpty || supervisors.isNotEmpty),
          'app_pids': apps, 'flutter_pids': supervisors};
        final metadata = File('${runDirectory.path}/supervisor.json');
        if (metadata.existsSync()) {
          final managed = jsonDecode(metadata.readAsStringSync()) as Map<String, dynamic>;
          if (supervisors.contains(managed['pid'])) value.addAll(managed);
        }
        stdout.writeln(jsonEncode(value));
        if (status) return;
      } else {
        final value = {'pid': pid, 'mode': 'debug', 'cwd': desktopRoot.path};
        final pending = File('${runDirectory.path}/supervisor.json.tmp');
        pending.writeAsStringSync(jsonEncode(value));
        final chmod = _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Uint16), int Function(Pointer<Utf8>, int)>('chmod');
        if (using((arena) => chmod(pending.path.toNativeUtf8(allocator: arena), 0x180)) != 0) {
          throw FileSystemException('Could not protect supervisor metadata', pending.path);
        }
        pending.renameSync('${runDirectory.path}/supervisor.json');
        stdout.writeln(jsonEncode(value));
        await stdout.flush();
        cancellation.throwIfCancelled();
        Directory.current = desktopRoot;
        exec(flutter.absolute.path, ['run', '-d', 'macos', '--debug', '--hot', '--no-pub', '--print-dtd'], environment);
      }
    } finally { closeLaunchLock(local); }
  } finally { closeLaunchLock(shared); }

  // Reuse keeps Moon's server task alive without taking over the original tty.
  final existing = {...apps, ...supervisors};
  while (processes('pid=,stat=').any((row) => existing.contains(row.$1) && !row.$2.startsWith('Z'))) {
    await Future<void>.delayed(const Duration(milliseconds: 250)).asCancellable(cancellation);
  }
}
