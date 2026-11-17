import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'download_asset.dart';
import 'web_deployment.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) throw ArgumentError('Expected build or dev');
  final command = switch (arguments.first) {
    'build' => ['build', 'web', '--release', '--no-web-resources-cdn', '--no-wasm-dry-run'],
    'dev' => ['run', '-d', 'chrome', '--web-browser-flag=--headless=new', '--web-browser-flag=--no-sandbox', '--web-port=8788'],
    _ => throw ArgumentError('Expected build or dev'),
  };
  final cancellation = CancellationToken();
  Process? child;
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) { cancellation.cancel(); child?.kill(signal); })).toList();
  try {
    final settings = await readWebDeployment(cancellation, optional: true);
    final serverUrl = Platform.environment['HAPPEN_SERVER_URL'] ?? switch (settings['server_hostname']) {
      final String hostname => 'https://$hostname',
      _ => null,
    };
    final wasm = await downloadAsset(sqliteWasmAsset, cancellation);
    await wasm.copy('packages/desktop/web/sqlite3.wasm');
    child = await Process.start(Platform.resolvedExecutable, ['compile', 'js', '-O2', '--no-source-maps',
      '-o', 'packages/desktop/web/database_worker.dart.js', 'packages/desktop/lib/database_worker.dart'], mode: ProcessStartMode.inheritStdio);
    final compiled = await child.exitCode;
    if (compiled != 0) { exitCode = compiled; return; }
    cancellation.throwIfCancelled();
    child = await Process.start('flutter', [...command, if (serverUrl != null) '--dart-define=HAPPEN_SERVER_URL=$serverUrl', ...arguments.skip(1)],
      workingDirectory: 'packages/desktop', mode: ProcessStartMode.inheritStdio);
    exitCode = await child.exitCode;
    if (exitCode == 0 && arguments.first == 'build') {
      // Version the complete asset set, including tree-shaken icon fonts.
      // Revalidated HTML selects one immutable release, so browser caches
      // cannot mix new code with old fonts or engine resources.
      final root = Directory('packages/desktop/build/web');
      final releases = Directory('${root.path}/releases');
      if (await releases.exists()) await releases.delete(recursive: true);
      await for (final entry in root.list()) {
        if (entry is File && RegExp(r'^(main\.[a-f0-9]+\.dart\.js|flutter_bootstrap\.[a-f0-9]+\.js)$').hasMatch(entry.uri.pathSegments.last)) {
          await entry.delete();
        }
      }
      const stable = {'index.html', '_headers', '_redirects', 'database_worker.dart.js', 'sqlite3.wasm'};
      final files = <String, File>{};
      await for (final entry in root.list(recursive: true, followLinks: false)) {
        if (entry is! File) continue;
        final relative = entry.path.substring(root.path.length + 1);
        if (!stable.contains(relative)) files[relative] = entry;
      }
      final manifest = StringBuffer();
      for (final path in files.keys.toList()..sort()) {
        manifest.writeln('$path:${await sha256.bind(files[path]!.openRead()).first}');
      }
      final hash = sha256.convert(utf8.encode(manifest.toString())).toString().substring(0, 20);
      for (final entry in files.entries) {
        final destination = File('${releases.path}/$hash/${entry.key}');
        await destination.parent.create(recursive: true);
        await entry.value.rename(destination.path);
      }
      final index = File('${root.path}/index.html');
      var html = (await index.readAsString()).replaceAll('<base href="/">', '<base href="/releases/$hash/">');
      if (serverUrl != null) {
        final origin = Uri.parse(serverUrl).origin;
        html = html.replaceFirst('<!-- happen-server-preconnect -->', '<link rel="preconnect" href="$origin" crossorigin>');
      }
      if (!html.contains('/releases/$hash/')) throw StateError('Flutter did not declare its asset base');
      await index.writeAsString(html, flush: true);
    }
  }
  finally {
    cancellation.cancel(); child?.kill();
    for (final signal in signals) { await signal.cancel(); }
  }
}
