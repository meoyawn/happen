import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('graceful server shutdown exits with an attached websocket client', () async {
    final root = await Directory.systemTemp.createTemp('server-shutdown-');
    final cancellation = TimeoutCancellationToken(const Duration(seconds: 30));
    Process? process;
    AgentClient? client;
    final subscriptions = <StreamSubscription<String>>[];
    final errors = StringBuffer();
    try {
      process = await Process.start(Platform.resolvedExecutable, ['--disable-dart-dev',
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('packages/server/test/fixtures/mcp_event_server.dart').absolute.path,
        jsonEncode({'directory': root.path, 'endpoint': 'http://127.0.0.1:1/responses'})]);
      final child = process;
      final kill = CancellationHook(cancellation, () => child.kill(ProcessSignal.sigkill));
      final ready = Completer<Json>();
      subscriptions.add(utf8.decoder.bind(child.stderr).listen(errors.write));
      subscriptions.add(utf8.decoder.bind(child.stdout).transform(const LineSplitter()).listen((line) {
        if (line.startsWith('{') && !ready.isCompleted) ready.complete(jsonObject(jsonDecode(line)));
      }));
      unawaited(child.exitCode.then((code) {
        if (!ready.isCompleted) ready.completeError(StateError('Server exited $code: $errors'));
      }));
      try {
        final info = await ready.future.asCancellable(cancellation);
        client = await AgentClient.connect(Uri.parse(info['uri'] as String), cancellation: cancellation);
        await client.request('ping');
        child.stdin.writeln('stop');
        await child.stdin.flush();
        expect(await child.exitCode.timeout(const Duration(seconds: 10)), 0, reason: errors.toString());
      } finally { kill.dispose(); }
    } finally {
      cancellation.cancel();
      process?.kill(ProcessSignal.sigkill);
      await process?.exitCode;
      await client?.close();
      await process?.stdin.close();
      for (final subscription in subscriptions) { await subscription.cancel(); }
      await root.delete(recursive: true);
    }
  });
}
