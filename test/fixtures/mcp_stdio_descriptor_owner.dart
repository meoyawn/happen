import 'dart:convert';
import 'dart:io';

import 'package:mcp/src/transport.dart';
import 'package:protocol/protocol.dart';

import 'stdio_unix.dart';

Future<void> main(List<String> arguments) async {
  final root = Directory(arguments.single), token = TimeoutCancellationToken(const Duration(seconds: 20)), http = HttpClient();
  final packages = File('.dart_tool/package_config.json').absolute.path, fixture = File('test/fixtures/mcp_stdio_lifecycle.dart').absolute.path;
  List<String> args(String mode, int sentinel) => ['--disable-dart-dev', '--packages=$packages', fixture, mode, root.path, '$sentinel'];
  final sentinel = inheritableSentinel(), results = <Json>[], connections = <McpConnection>[];
  try {
    // Run before this owner's first Dart Process.start: Dart's process-wide
    // waitpid(-1) reaper otherwise races an independently spawned native oracle.
    final oracle = await inheritedProbe(args('probe', sentinel), root, token);
    await Link('${root.path}/dart-fixture').create(Platform.resolvedExecutable);
    final wrapper = File('${root.path}/executable-text'); await wrapper.writeAsString('exec "\$@"\n');
    if ((await Process.run('/bin/chmod', ['700', wrapper.path])).exitCode != 0) throw StateError('Cannot make fixture executable');
    for (final (launch, command, prefix) in [
      ('absolute', Platform.resolvedExecutable, <String>[]), ('relative', './dart-fixture', <String>[]),
      ('shell fallback', './executable-text', [Platform.resolvedExecutable]),
    ]) {
      final c = McpConnection({'command': command, 'cwd': root.path, 'args': [...prefix, ...args('descriptor', sentinel)]}, http, (_) {});
      connections.add(c); await c.connect(token);
      final result = await c.request('tools/call', {'name': 'probe'}, cancellation: token); await c.close();
      results.add({'launch': launch, 'result': result['structuredContent'], 'parentFlags': fdFlags(sentinel)});
    }
    stdout.writeln(jsonEncode({'oracleStatus': oracle.exitCode, 'oracleSawSentinel': jsonDecode(oracle.stdout), 'oracleStderr': oracle.stderr, 'results': results}));
  } finally { token.cancel(); await Future.wait(connections.map((c) => c.close())); closeFd(sentinel); http.close(force: true); }
}
