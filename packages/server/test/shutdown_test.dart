import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

import '../../../test/support/thread.dart';
import '../../../test/support/thread_names.dart';

void main() {
  test('embedded quit cancels a live response and commits the interrupted turn', () async {
    final root = await Directory.systemTemp.createTemp('embedded-quit-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>(), disconnected = Completer<void>();
    Socket? response;
    addTearDown(() async { response?.destroy(); await provider.close(force: true); });
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      if (await respondToThreadName(request, body)) return;
      request.response.headers.contentType = ContentType('text', 'event-stream');
      final socket = response = await request.response.detachSocket(writeHeaders: true);
      socket.listen((_) {}, onDone: disconnected.complete);
      started.complete();
    });

    final server = await AgentServer.startEmbedded(directory: root.path, skillsHome: root.path,
      configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
    addTearDown(server.close);
    final client = await AgentClient.connect(server.uri, token: server.token);
    addTearDown(client.close);
    final id = await createThread(client, {'cwd': root.path, 'settings': {'transport': 'http'}});
    await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Remember this prompt'}]});
    await started.future.timeout(const Duration(seconds: 10));

    await server.closeForExit().timeout(const Duration(seconds: 5));
    await disconnected.future.timeout(const Duration(seconds: 5));
    final thread = TaskStore(root.path, id, create: false);
    try {
      expect(thread.db.select('SELECT status FROM thread_turns').single['status'], 'interrupted');
      expect(thread.metadata('status'), 'idle');
    } finally { thread.close(); }
  });

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
