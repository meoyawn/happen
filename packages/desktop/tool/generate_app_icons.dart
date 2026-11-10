import 'dart:io';

import 'package:protocol/protocol.dart';

/// Render with Flutter's headless engine; never launch or focus the desktop app.
Future<void> main(List<String> arguments) async {
  if (arguments.length > 1) throw ArgumentError('Usage: dart tool/generate_app_icons.dart [flutter-sdk]');
  final desktop = File.fromUri(Platform.script).parent.parent;
  final workspace = desktop.parent.parent;
  final sdkPath = arguments.isNotEmpty ? Directory(arguments.single).absolute.path :
    File(Platform.resolvedExecutable).resolveSymbolicLinksSync().split('/bin/cache/dart-sdk/').first;
  final cache = Directory('$sdkPath/bin/cache/artifacts/engine');
  final engine = cache.listSync().whereType<Directory>()
    .where((directory) => File('${directory.path}/flutter_tester').existsSync()).firstOrNull;
  if (engine == null) throw StateError('Pass a Flutter SDK with cached desktop artifacts');
  final output = Directory('${workspace.path}/.local/icon-design')..createSync(recursive: true);
  final cancellation = TimeoutCancellationToken(const Duration(minutes: 2));
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();

  Future<void> run(String executable, List<String> args) async {
    cancellation.throwIfCancelled();
    final process = await Process.start(executable, args, workingDirectory: desktop.path);
    final hook = CancellationHook(cancellation, process.kill);
    final out = process.stdout.toList(), err = process.stderr.toList();
    try {
      final code = await process.exitCode.asCancellable(cancellation);
      final stdoutBytes = await out, stderrBytes = await err;
      if (code != 0) {
        for (final bytes in stdoutBytes) { stdout.add(bytes); }
        for (final bytes in stderrBytes) { stderr.add(bytes); }
        throw ProcessException(executable, args, 'Icon generation failed', code);
      }
    } finally { hook.dispose(); process.kill(); }
  }

  try {
    await run('$sdkPath/bin/cache/dart-sdk/bin/dartaotruntime', [
      '${engine.path}/frontend_server_aot.dart.snapshot',
      '--sdk-root', '${cache.path}/common/flutter_patched_sdk', '--target', 'flutter',
      '--no-print-incremental-dependencies', '--packages', '${workspace.path}/.dart_tool/package_config.json',
      '--output-dill', '${output.path}/app_icons.dill', '${desktop.path}/tool/app_icon_artwork.dart',
    ]);
    await run('${engine.path}/flutter_tester', ['--non-interactive', '--run-forever',
      '--disable-dart-dev', '${output.path}/app_icons.dill']);
    stdout.writeln('Generated release/debug Dock icons, menu bar templates, sidebar SVG, and design/icon-preview.png.');
  } finally {
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
  }
}
