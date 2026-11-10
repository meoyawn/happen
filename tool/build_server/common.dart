import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:yaml/yaml.dart';

export 'package:cancellation_token/cancellation_token.dart';

String serverPlatform(String architecture) => switch (architecture) {
  'x64' => 'linux/amd64',
  'arm64' => 'linux/arm64',
  _ => throw ArgumentError('Unsupported server architecture: $architecture'),
};

Future<void> withBuildCancellation(Future<void> Function(CancellationToken) build) async {
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  try { await build(cancellation); }
  finally {
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<String> buildServerImage(Directory root, String architecture, CancellationToken cancellation) async {
  final image = 'happen-server-builder:dart-3.13.7-$architecture';
  await runBuildProcess('docker', ['build', '--quiet', '--platform', serverPlatform(architecture), '--tag', image,
    '--file', '${root.path}/tool/build_server/Dockerfile', '${root.path}/tool/build_server'], cancellation);
  return image;
}

Future<void> runServerBuilder(String image, Directory source, String architecture,
    List<String> arguments, CancellationToken cancellation) async {
  final container = 'happen-server-build-$pid-${DateTime.now().microsecondsSinceEpoch}';
  try {
    await runBuildProcess('docker', ['run', '--rm', '--name', container, '--platform', serverPlatform(architecture),
      '--mount', 'type=bind,source=${source.path},target=/source',
      '--mount', 'type=volume,source=happen-server-pub-$architecture,target=/root/.pub-cache', image,
      ...arguments], cancellation);
  } finally {
    if (cancellation.isCancelled) await Process.run('docker', ['rm', '-f', container]);
  }
}

Future<void> resolveServerPackages(String image, Directory root, Directory source,
    String architecture, CancellationToken cancellation) async {
  await File('${root.path}/pubspec.lock').copy('${source.path}/pubspec.lock');
  await runServerBuilder(image, source, architecture, ['pub', 'get'], cancellation);
  final expected = (loadYaml(await File('${root.path}/pubspec.lock').readAsString()) as YamlMap)['packages'] as YamlMap;
  final resolved = (loadYaml(await File('${source.path}/pubspec.lock').readAsString()) as YamlMap)['packages'] as YamlMap;
  for (final name in resolved.keys) {
    final package = resolved[name] as YamlMap;
    if (package['source'] == 'path') continue;
    final locked = expected[name] as YamlMap?;
    if (locked == null || package['version'] != locked['version'] || package['source'] != locked['source'] ||
        jsonEncode(package['description']) != jsonEncode(locked['description'])) {
      throw StateError('The Linux builder changed locked dependency $name; update pubspec.lock first');
    }
  }
}

Future<String> runBuildProcess(String executable, List<String> arguments, CancellationToken cancellation,
    {bool capture = false, String? workingDirectory}) async {
  cancellation.throwIfCancelled();
  final process = await Process.start(executable, arguments, workingDirectory: workingDirectory);
  final exit = process.exitCode.asCancellable(cancellation, onCancel: () { process.kill(); });
  exit.ignore();
  final output = StringBuffer();
  try {
    await process.stdin.close();
    await Future.wait([
      process.stdout.forEach((bytes) { if (capture) { output.write(utf8.decode(bytes)); } else { stdout.add(bytes); } }),
      process.stderr.forEach(stderr.add),
    ]);
    final code = await exit;
    cancellation.throwIfCancelled();
    if (code != 0) throw StateError('$executable failed ($code)');
    return output.toString().trim();
  } finally {
    process.kill();
    await process.exitCode;
  }
}
