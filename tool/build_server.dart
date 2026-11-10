import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:yaml/yaml.dart';

import 'build_server/common.dart';
import 'native_contracts.dart' show linuxNativeContracts;

// Freeze only the server's Dart workspace packages. Neither local credentials,
// Flutter, build output nor .git are ever mounted into the Linux builder.
Future<void> main(List<String> arguments) async {
  final compile = arguments.firstOrNull == '--compile';
  final positional = compile ? arguments.skip(1).toList() : arguments;
  if (positional.length > 1) throw ArgumentError('Usage: dart tool/build_server.dart [x64|arm64]');
  final architecture = positional.singleOrNull ?? 'x64';
  serverPlatform(architecture);
  final root = Directory.fromUri(Platform.script).parent.parent;
  await withBuildCancellation((cancellation) => compile
    ? compileServer(root, architecture, cancellation)
    : buildServer(root, architecture, cancellation));
}

Future<void> buildServer(Directory root, String architecture, CancellationToken cancellation) async {
  serverPlatform(architecture);
  await runBuildProcess('moon', ['run', architecture == 'x64' ? 'build-server' : 'build-server-arm64'],
    cancellation, workingDirectory: root.path);
}

Future<void> compileServer(Directory root, String architecture, CancellationToken cancellation) async {
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
    final manifest = loadYaml(await File('${root.path}/pubspec.yaml').readAsString()) as YamlMap;
    final workspace = <String, String>{};
    for (final path in (manifest['workspace'] as YamlList).cast<String>()) {
      final spec = loadYaml(await File('${root.path}/$path/pubspec.yaml').readAsString()) as YamlMap;
      workspace[spec['name'] as String] = path;
    }
    final packages = <String>{};
    Future<void> include(String name) async {
      if (!packages.add(name)) return;
      final path = workspace[name]!;
      final spec = loadYaml(await File('${root.path}/$path/pubspec.yaml').readAsString()) as YamlMap;
      for (final dependency in (spec['dependencies'] as YamlMap?)?.keys.whereType<String>() ?? const <String>[]) {
        if (workspace.containsKey(dependency)) await include(dependency);
      }
    }
    await include('server');
    final digest = <int>[];
    for (final name in packages.toList()..sort()) {
      final path = workspace[name]!;
      final files = await runBuildProcess('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', path],
        cancellation, workingDirectory: root.path, capture: true);
      for (final relative in (files.split('\x00').where((path) => path.isNotEmpty).toSet().toList()..sort())) {
        cancellation.throwIfCancelled();
        final local = relative.substring(path.length + 1);
        if (local != 'pubspec.yaml' && !['bin/', 'catalog/', 'lib/'].any(local.startsWith)) continue;
        final file = File('${root.path}/$relative');
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        digest..addAll(utf8.encode('$relative\x00'))..addAll(sha256.convert(bytes).bytes);
        final destination = File('${source.path}/$relative');
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(bytes);
      }
    }
    // Moon restores these outputs independently; this step never runs hooks.
    for (final library in linuxNativeContracts.keys) {
      final destination = File('${source.path}/native/$library');
      await destination.parent.create(recursive: true);
      await File('${output.path}/native/$library').copy(destination.path);
    }
    for (final relative in ['tool/cli_native_bootstrap.dart', 'tool/native_contracts.dart', 'tool/build_server/embed.dart']) {
      final bytes = await File('${root.path}/$relative').readAsBytes();
      digest..addAll(utf8.encode('$relative\x00'))..addAll(sha256.convert(bytes).bytes);
      final destination = File('${source.path}/$relative');
      await destination.parent.create(recursive: true);
      await destination.writeAsBytes(bytes);
    }
    await File('${source.path}/pubspec.yaml').writeAsString('name: happen_server_build\npublish_to: none\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\nworkspace:\n'
      '${(packages.toList()..sort()).map((name) => '  - ${workspace[name]}').join('\n')}\n');
    stdout.writeln('Building a single-file Ubuntu 24.04 AOT server ($architecture).');
    final image = await buildServerImage(root, architecture, cancellation);
    await resolveServerPackages(image, root, source, architecture, cancellation);
    await Directory('${source.path}/release').create();
    await runServerBuilder(image, source, architecture,
      ['tool/build_server/embed.dart', '/source/native', '/source/release/happen-server'], cancellation);
    final embedded = File('${source.path}/release/happen-server');
    final native = jsonObject(jsonDecode(await File('${embedded.path}.native.json').readAsString()));
    final checksum = sha256.convert(await embedded.readAsBytes()).toString();
    final report = {'target': 'ubuntu-24.04-$architecture', 'dartSdk': '3.13.7',
      'sourceSha256': sha256.convert(digest).toString(), 'packages': packages.toList()..sort(),
      ...native, 'sha256': checksum, 'executableBytes': await embedded.length()};
    final executable = '${output.path}/happen-server';
    await embedded.copy('$executable.pending');
    await runBuildProcess('chmod', ['755', '$executable.pending'], cancellation);
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
