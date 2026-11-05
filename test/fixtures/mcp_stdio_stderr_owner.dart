// Own the FD count and block the actual stderr reader's isolate before teardown.
// A separate process also captures the normal production stderr log, without a
// log injection/export seam in McpConnection.
import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart';
import 'package:mcp/src/transport.dart';
import 'package:protocol/protocol.dart';

import 'stdio_unix.dart';

Future<void> main(List<String> arguments) async {
  final root = Directory(arguments[0]), cleanup = arguments[1], diagnostic = 'queued diagnostic before $cleanup';
  final token = TimeoutCancellationToken(const Duration(seconds: 15)), http = HttpClient();
  // Initialize Dart's process/event infrastructure before the process-wide FD baseline.
  await Process.run('/usr/bin/true', []);
  final baseline = fdCount();
  final config = {'command': Platform.resolvedExecutable, 'args': ['--disable-dart-dev',
    '--packages=${File('.dart_tool/package_config.json').absolute.path}', File('test/fixtures/mcp_stdio_lifecycle.dart').absolute.path,
    'stderr', root.path, diagnostic]};
  final connection = McpConnection(config, http, (_) {});
  final manager = McpManager(http: http, onEvent: (_, _) {});
  try {
    if (cleanup == 'shutdown') await connection.connect(token);
    else await manager.configure({'stderr': config}, token);
    final server = int.parse(File('${root.path}/server.pid').readAsStringSync()), escaped = int.parse(File('${root.path}/escaped.pid').readAsStringSync());
    final isolated = getpgid(server) == server, escapedGroup = getpgid(escaped) == escaped;
    File('${root.path}/emit').writeAsStringSync('emit');
    // Do not yield: the reader must not log anything until cleanup begins.
    for (var attempt = 0; attempt < 250 && !File('${root.path}/written').existsSync(); attempt++) { sleep(const Duration(milliseconds: 20)); }
    if (!File('${root.path}/written').existsSync()) throw StateError('Fixture did not write queued stderr');
    if (cleanup == 'shutdown') await connection.close();
    else await manager.configure({}, token); // Genuine config-owner disposal, not fake GC.
    var after = fdCount();
    for (var attempt = 0; attempt < 100 && after != baseline; attempt++) {
      await cancellableDelay(const Duration(milliseconds: 10), token); after = fdCount();
    }
    stdout.writeln(jsonEncode({'baseline': baseline, 'after': after, 'isolated': isolated,
      'escapedGroup': escapedGroup, 'escapedAlive': exists(escaped)}));
  } finally { token.cancel(); await connection.close(); await manager.close(); http.close(force: true); }
}
