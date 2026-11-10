// Adapted from Codex 37103d7f01e8 core/src/code_mode_host_lifecycle_tests.rs:
// one replacement for concurrent admission; a lost generation never replays work.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';
import 'package:mcp/mcp.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

import 'support/openai_output.dart';
import 'support/thread.dart';
import 'support/thread_names.dart';
import 'fixtures/stdio_unix.dart' show exists, kill;

void main() {
  late Directory root;
  late AgentServer server;
  late AgentClient client;
  late HttpServer provider;
  late CancellationToken lifetime;

  setUp(() async {
    lifetime = TimeoutCancellationToken(const Duration(seconds: 20));
    root = await Directory.systemTemp.createTemp('network-recovery-');
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
  tearDown(() async {
    lifetime.cancel();
    await client.close();
    try { await server.close(); }
    finally { await provider.close(force: true); await root.delete(recursive: true); }
  });
  Future<void> start(Json servers) async {
    final config = await File('${root.path}/config.yaml').writeAsString(jsonEncode({'mcp_servers': servers}));
    server = await AgentServer.startLocal(directory: root.path, configPath: config.path,
      endpoint: 'http://127.0.0.1:${provider.port}/responses', apiKeyEnv: 'HAPPEN_RECOVERY_TEST_KEY', telemetry: false);
    client = AgentClient.local(server);
  }
  Future<String> create() => createThread(client, {'cwd': root.path, 'model': 'gpt-6.1-sol'});

  test('concurrent new threads recover one lost network generation and reuse healthy ownership', () async {
    await start({});
    final originalThread = await create(), original = server.network;
    final statuses = <String>[];
    final cancelledWaiter = CancellationToken();
    final events = client.events.stream.listen((event) {
      if (event['method'] == 'happen/network/status') {
        final status = event['params']['status'] as String;
        statuses.add(status);
        if (status == 'recovering') cancelledWaiter.cancel();
      }
    });
    addTearDown(events.cancel);
    original.isolate.kill(priority: Isolate.immediate);
    await original.done.asCancellable(lifetime);
    final cancelled = expectLater(client.mcpInventory(cancellation: cancelledWaiter), throwsA(isA<CancelledException>()));
    final threads = await Future.wait(List.generate(8, (_) => create())).asCancellable(lifetime);
    await cancelled;
    expect(threads.toSet(), hasLength(8));
    expect(server.network, isNot(same(original)));
    final recovered = server.network;
    expect(jsonObject(await client.request('providers.list'))['providers'], isNotEmpty);
    expect(jsonObject(await client.request('thread/read', {'threadId': originalThread, 'includeTurns': true}))['thread']['id'], originalThread);
    expect(server.network, same(recovered), reason: 'Healthy ownership must survive reads and further admission.');
    expect(statuses.where((status) => status == 'recovering'), hasLength(1));
    expect(statuses.where((status) => status == 'ready'), hasLength(1));
  });

  test('loss during an admitted tool call ends the turn without replay and the same chat can continue', () async {
    final mcp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final admitted = Completer<void>(), release = Completer<void>();
    var effects = 0;
    final prompts = <String>[];
    addTearDown(() async { if (!release.isCompleted) release.complete(); await mcp.close(force: true); });
    mcp.listen((request) async {
      try {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        final Json result;
        switch (body['method']) {
          case 'server/discover':
            result = {'supportedVersions': ['2026-07-28'], 'serverInfo': {'name': 'effect', 'version': '1'},
              'capabilities': {'tools': <String, dynamic>{}}};
          case 'tools/list':
            result = {'tools': [{'name': 'record', 'description': 'Record an external side effect', 'inputSchema': {'type': 'object'}}]};
          case 'tools/call':
            effects++;
            if (!admitted.isCompleted) admitted.complete();
            await release.future;
            result = {'content': [{'type': 'text', 'text': 'committed'}]};
          default: throw StateError('Unexpected MCP method: ${body['method']}');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}));
        await request.response.close();
      } on HttpException { /* The deliberately killed generation disconnected. */ }
      on SocketException { /* The deliberately killed generation disconnected. */ }
    });
    provider.listen((request) async {
      try {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        if (await respondToThreadName(request, body)) return;
        final input = (body['input'] as List).map(jsonObject).toList();
        final prompt = openAIMessageText(input.lastWhere((item) => item['role'] == 'user'));
        prompts.add(prompt);
        request.response.headers.contentType = ContentType('text', 'event-stream');
        request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
          'status': 'completed', 'output': [if (prompt == 'record once') {
            'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'record-once',
            'input': 'text(await tools.mcp__effect__record({}));',
          } else {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'recovered'}]}],
          'usage': {'input_tokens': 10, 'output_tokens': 2},
        }})}\n\n');
        await request.response.close();
      } on HttpException { /* Cancellation owns the old response. */ }
      on SocketException { /* Cancellation owns the old response. */ }
    });
    await start({'effect': {'url': 'http://127.0.0.1:${mcp.port}/mcp', 'oauth': false, 'legacy_fallback': false}});
    final thread = await create();
    final interrupted = runTurn(client, thread, prompt: 'record once');
    await admitted.future.asCancellable(lifetime);
    final original = server.network;
    original.isolate.kill(priority: Isolate.immediate);
    await original.done.asCancellable(lifetime);
    expect((await interrupted.asCancellable(lifetime))['status'], isIn(['failed', 'interrupted']));
    expect((await runTurn(client, thread, prompt: 'continue'))['status'], 'completed');
    expect(effects, 1, reason: 'A committed tool action cannot be replayed after losing its reply.');
    expect(prompts.where((prompt) => prompt == 'record once'), hasLength(1));
  });

  test('network exit reaps its MCP child before admitting a replacement', () async {
    final fixture = File('test/fixtures/mcp_stdio_lifecycle.dart').absolute.path;
    final packages = File('.dart_tool/package_config.json').absolute.path;
    await start({'owned': {'command': Platform.resolvedExecutable,
      'args': ['--disable-dart-dev', '--packages=$packages', fixture, 'in-flight', root.path]}});
    await client.request('mcp.status').asCancellable(lifetime);
    final child = int.parse(await File('${root.path}/server.pid').readAsString());
    addTearDown(() { if (exists(child)) kill(child, 9); });
    expect(exists(child), true);
    final original = server.network;
    original.isolate.kill(priority: Isolate.immediate);
    await original.done.asCancellable(lifetime);
    expect(exists(child), false, reason: 'The failed worker must not leave a tool process behind.');
    await create();
    expect(server.network, isNot(same(original)));
  }, skip: Platform.isWindows ? 'Unix process group ownership' : false);

  test('a repeatedly crashing MCP peer cannot stop sibling tools or local thread admission', () async {
    final fixture = File('test/fixtures/mcp_stdio.dart').absolute.path;
    await start({for (final name in ['broken', 'healthy']) name: {
      'command': Platform.resolvedExecutable, 'args': [fixture, name],
    }});
    await client.request('mcp.status').asCancellable(lifetime);
    final original = server.network;
    for (var attempt = 0; attempt < 3; attempt++) {
      await expectLater(client.request('mcp.request', {'server': 'broken', 'method': 'tools/call',
        'arguments': {'name': 'probe', 'arguments': {'action': 'crash'}}}).asCancellable(lifetime),
        throwsA(predicate<Object>((error) => '$error'.contains('MCP'))));
      final healthy = jsonObject(await client.request('mcp.request', {'server': 'healthy', 'method': 'tools/call',
        'arguments': {'name': 'probe', 'arguments': {'action': 'status'}}}).asCancellable(lifetime));
      expect(jsonObject(jsonDecode(healthy['content'][0]['text'] as String))['pid'], isA<int>());
      await create();
      expect(server.network, same(original));
      while (true) {
        final status = (await client.request('mcp.status').asCancellable(lifetime) as List).map(jsonObject);
        if (status.any((entry) => entry['name'] == 'broken' && entry['state'] == 'ready')) break;
        await cancellableDelay(const Duration(milliseconds: 10), lifetime);
      }
    }
  });

  test('shutdown cancels shared recovery before a replacement can outlive its server', () async {
    await start({});
    final original = server.network, closed = Completer<void>();
    final events = client.events.stream.listen((event) {
      if (event['method'] == 'happen/network/status' && event['params']['status'] == 'recovering') {
        unawaited(server.close().then<void>((_) => closed.complete(), onError: closed.completeError));
      }
    });
    addTearDown(events.cancel);
    original.isolate.kill(priority: Isolate.immediate);
    await original.done.asCancellable(lifetime);
    final pending = expectLater(client.request('providers.list'), throwsA(isA<CancelledException>()));
    await closed.future.asCancellable(lifetime);
    await pending;
    expect(server.network, same(original));
  });

  test('a rejected shutdown still cleans owned tool processes and preserves the shutdown error', () async {
    await start({});
    final owner = await IsolateOwner.start(_rejectShutdown, {
      'root': root.path, 'fixture': File('test/fixtures/mcp_stdio_lifecycle.dart').absolute.path,
      'packages': File('.dart_tool/package_config.json').absolute.path,
    }, cleanup: cleanupMcpProcess);
    final child = int.parse(await File('${root.path}/server.pid').readAsString());
    addTearDown(() { if (exists(child)) kill(child, 9); });
    expect(exists(child), true);
    await expectLater(owner.close(), throwsA(isA<RemoteFailure>().having((error) => error.message, 'shutdown failure', 'shutdown rejected')));
    expect(exists(child), false, reason: 'An error reply must not discard the owner exit cleanup.');
  }, skip: Platform.isWindows ? 'Unix process group ownership' : false);
}

Future<void> _rejectShutdown(List<Object?> arguments) async {
  final config = jsonObject(arguments[1]), http = HttpClient();
  final manager = McpManager(http: http, onEvent: (_, _) {});
  final cancellation = CancellationToken();
  await manager.configure({'owned': {'command': Platform.resolvedExecutable,
    'args': ['--disable-dart-dev', '--packages=${config['packages']}', config['fixture'], 'in-flight', config['root']]}}, cancellation);
  final inbox = ReceivePort();
  (arguments[0] as SendPort).send(inbox.sendPort);
  // This owner rejects shutdown and keeps its resources. The parent must
  // force exit, then run the same exit cleanup used by the real network owner.
  await for (final raw in inbox) {
    final request = jsonObject(raw);
    (request['reply'] as SendPort?)?.send({'error': 'shutdown rejected'});
  }
}
