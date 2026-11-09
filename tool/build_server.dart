import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:yaml/yaml.dart';

// Freeze only the server's Dart workspace packages. Neither local credentials,
// Flutter, build output nor .git are ever mounted into the Linux builder.
Future<void> main(List<String> arguments) async {
  final architecture = arguments.singleOrNull ?? 'x64';
  if (!{'x64', 'arm64'}.contains(architecture)) throw ArgumentError('Usage: dart tool/build_server.dart [x64|arm64]');
  final token = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((signal) => signal.watch().listen((_) => token.cancel())).toList();
  try { await buildServer(Directory.fromUri(Platform.script).parent.parent, architecture, token); }
  finally { token.cancel(); for (final signal in signals) { await signal.cancel(); } }
}

Future<void> buildServer(Directory root, String architecture, CancellationToken cancellation) async {
  final source = await Directory.systemTemp.createTemp('happen-server-build-');
  final output = Directory('${root.path}/build/server/linux-$architecture');
  await output.create(recursive: true);
  final lock = await File('${output.path}/build.lock').open(mode: FileMode.append);
  var locked = false;
  try {
    while (!locked) {
      cancellation.throwIfCancelled();
      try { await lock.lock(FileLock.exclusive); locked = true; }
      on FileSystemException { await cancellableDelay(const Duration(milliseconds: 100), cancellation); }
    }
    final manifest = loadYaml(await File('${root.path}/pubspec.yaml').readAsString()) as Map;
    final workspace = <String, String>{};
    for (final path in manifest['workspace'] as List) {
      final spec = loadYaml(await File('${root.path}/$path/pubspec.yaml').readAsString()) as Map;
      workspace[spec['name'] as String] = path as String;
    }
    final packages = <String>{};
    Future<void> include(String name) async {
      if (!packages.add(name)) return;
      final path = workspace[name]!;
      final spec = loadYaml(await File('${root.path}/$path/pubspec.yaml').readAsString()) as Map;
      for (final dependency in (spec['dependencies'] as Map? ?? {}).keys.whereType<String>()) {
        if (workspace.containsKey(dependency)) await include(dependency);
      }
    }
    await include('server');
    final digest = <int>[];
    for (final name in packages.toList()..sort()) {
      final path = workspace[name]!;
      final files = await Process.run('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', path], workingDirectory: root.path);
      if (files.exitCode != 0) throw StateError('Cannot snapshot server inputs');
      for (final relative in ((files.stdout as String).split('\x00').where((path) => path.isNotEmpty).toSet().toList()..sort())) {
        if (relative.substring(path.length + 1).startsWith('test/')) continue;
        final file = File('${root.path}/$relative');
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        digest..addAll(utf8.encode('$relative\x00'))..addAll(sha256.convert(bytes).bytes);
        final destination = File('${source.path}/$relative');
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(bytes);
      }
    }
    // Materialize the vendored QuickJS submodule's native sources explicitly.
    final nativeSources = await Directory('${root.path}/packages/code_mode/native/quickjs').list().toList();
    nativeSources.sort((a, b) => a.path.compareTo(b.path));
    for (final file in nativeSources) {
      if (file is! File || !(file.path.endsWith('.c') || file.path.endsWith('.h') || file.uri.pathSegments.last == 'LICENSE')) continue;
      final relative = 'packages/code_mode/native/quickjs/${file.uri.pathSegments.last}';
      final bytes = await file.readAsBytes();
      digest..addAll(utf8.encode('$relative\x00'))..addAll(sha256.convert(bytes).bytes);
      final destination = File('${source.path}/$relative');
      await destination.parent.create(recursive: true);
      await destination.writeAsBytes(bytes);
    }
    for (final relative in ['tool/cli_native_bootstrap.dart', 'tool/build_server/embed.dart']) {
      final bytes = await File('${root.path}/$relative').readAsBytes();
      digest..addAll(utf8.encode('$relative\x00'))..addAll(sha256.convert(bytes).bytes);
      final destination = File('${source.path}/$relative');
      await destination.parent.create(recursive: true);
      await destination.writeAsBytes(bytes);
    }
    await File('${source.path}/pubspec.yaml').writeAsString('name: happen_server_build\npublish_to: none\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\nworkspace:\n'
      '${(packages.toList()..sort()).map((name) => '  - ${workspace[name]}').join('\n')}\n');
    await File('${root.path}/pubspec.lock').copy('${source.path}/pubspec.lock');
    final platform = architecture == 'x64' ? 'linux/amd64' : 'linux/arm64';
    final image = 'happen-server-builder:dart-3.13.7-$architecture';
    stdout.writeln('Building a single-file Ubuntu 24.04 AOT server ($architecture).');
    await deployRun('docker', ['build', '--quiet', '--platform', platform, '--tag', image,
      '--file', '${root.path}/tool/build_server/Dockerfile', '${root.path}/tool/build_server'], cancellation);
    // Package resolution and native hooks run entirely inside the container.
    final container = 'happen-server-build-${newId()}';
    final run = ['run', '--rm', '--name', container, '--platform', platform,
      '--mount', 'type=bind,source=${source.path},target=/source',
      '--mount', 'type=volume,source=happen-server-pub-$architecture,target=/root/.pub-cache', image];
    final hook = CancellationHook(cancellation, () => unawaited(Process.run('docker', ['rm', '-f', container])));
    try {
      await deployRun('docker', [...run, 'pub', 'get'], cancellation);
      await deployRun('docker', [...run, 'build', 'cli', '--target=packages/server/bin/happen_server.dart', '--output=/source/release'], cancellation);
      await deployRun('docker', [...run, 'tool/build_server/embed.dart', '/source/release/bundle', '/source/release/happen-server'], cancellation);
    } finally { hook.dispose(); }
    final embedded = File('${source.path}/release/happen-server');
    final native = jsonObject(jsonDecode(await File('${embedded.path}.native.json').readAsString()));
    final checksum = sha256.convert(await embedded.readAsBytes()).toString();
    final report = {'target': 'ubuntu-24.04-$architecture', 'dartSdk': '3.13.7',
      'sourceSha256': sha256.convert(digest).toString(), 'packages': packages.toList()..sort(),
      ...native, 'sha256': checksum, 'executableBytes': await embedded.length()};
    final executable = '${output.path}/happen-server';
    await embedded.copy('$executable.pending');
    await deployRun('chmod', ['755', '$executable.pending'], cancellation);
    await File('$executable.pending').rename(executable);
    await File('$executable.sha256').writeAsString('$checksum\n');
    await File('${output.path}/build-report.json').writeAsString('${jsonEncode(report)}\n');
    stdout.writeln('Built $executable ($checksum)');
  } finally {
    if (locked) await lock.unlock();
    await lock.close();
    await source.delete(recursive: true);
  }
}

Future<String> deployRun(String executable, List<String> arguments, CancellationToken cancellation, {bool capture = false}) async {
  cancellation.throwIfCancelled();
  final process = await Process.start(executable, arguments);
  final hook = CancellationHook(cancellation, () => process.kill());
  final output = StringBuffer();
  try {
    await process.stdin.close();
    await Future.wait([
      process.stdout.forEach((bytes) { if (capture) { output.write(utf8.decode(bytes)); } else { stdout.add(bytes); } }),
      process.stderr.forEach(stderr.add),
    ]);
    final code = await process.exitCode;
    cancellation.throwIfCancelled();
    if (code != 0) throw StateError('$executable failed ($code)');
    return output.toString().trim();
  } finally { hook.dispose(); }
}
