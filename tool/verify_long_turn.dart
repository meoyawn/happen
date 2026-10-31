import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

// Real-time companion to the accelerated server regression. Both provider
// transports cross the old ten-minute turn and nested model-call deadlines.
// An optional seconds argument permits a quick fixture/completion check.
Future<void> main(List<String> args) async {
  final seconds = args.isEmpty ? 606 : int.parse(args.single);
  if (seconds < 1) throw ArgumentError('Duration must be positive seconds');
  final duration = Duration(seconds: seconds);
  final root = await Directory.systemTemp.createTemp('happen-long-turn-');
  final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final release = Completer<void>(), started = Completer<void>();
  final sockets = <WebSocket>[];
  final pulses = <Timer>[];
  AgentServer? server;
  AgentClient? client;
  StreamSubscription<Json>? events;
  var requests = 0;
  Future<void> respond(Future<void> Function(String) send) async {
    requests++;
    await send(jsonEncode({'type': 'response.created'}));
    final pulse = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(send(jsonEncode({'type': 'response.output_text.delta', 'delta': '.'}))
          .catchError((Object _) {}));
    });
    pulses.add(pulse);
    if (requests == 2 && !started.isCompleted) started.complete();
    try {
      await release.future;
      pulse.cancel();
      await send(jsonEncode({'type': 'response.completed', 'response': {
        'status': 'completed', 'output': [
          {'type': 'message', 'role': 'assistant', 'content': [
            {'type': 'output_text', 'text': 'Completed after release'},
          ]},
        ],
      }}));
    } finally {
      pulse.cancel();
    }
  }

  provider.listen((request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((_) async {
        await respond((data) async {
          if (socket.readyState == WebSocket.open) socket.add(data);
        });
      });
    } else {
      try {
        await request.drain<void>();
        request.response.headers.contentType = ContentType('text', 'event-stream');
        request.response.bufferOutput = false;
        Future<void> writes = Future<void>.value();
        await respond((data) {
          return writes = writes.then((_) async {
            request.response.write('data: $data\n\n');
            await request.response.flush();
          });
        });
      } finally {
        await request.response.close();
      }
    }
  });

  try {
    await File('${root.path}/config.yaml').writeAsString('{}');
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture',
      'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    final work = await Directory('${root.path}/work').create();
    server = await AgentServer.startEmbedded(
      directory: root.path, configPath: '${root.path}/config.yaml',
      endpoint: 'http://127.0.0.1:${provider.port}/responses',
    );
    client = await AgentClient.connect(server.uri);
    final terminals = <Json>[];
    final finished = Completer<void>();
    events = client.events.stream.listen((event) {
      if ({'turn.completed', 'turn.failed', 'turn.cancelled'}.contains(event['type'])) {
        terminals.add(event);
        if (terminals.length == 2 && !finished.isCompleted) finished.complete();
      }
    });
    final ids = <String>[];
    for (final transport in ['http', 'websocket']) {
      ids.add(jsonObject(await client.request('task.start', {
        'cwd': work.path, 'prompt': 'Keep streaming until released',
        'settings': {'transport': transport},
      }))['task_id'] as String);
    }
    await started.future.timeout(const Duration(seconds: 15));
    final watch = Stopwatch()..start();
    stdout.writeln('HTTP/SSE and WebSocket turns started; checking for $seconds seconds.');
    while (watch.elapsed < duration) {
      final remaining = duration - watch.elapsed;
      await Future<void>.delayed(remaining < const Duration(minutes: 1) ? remaining : const Duration(minutes: 1));
      if (terminals.isNotEmpty) throw StateError('Turn stopped before release: $terminals');
      for (final id in ids) {
        final status = jsonObject(await client.request('task.subscribe', {'task_id': id}));
        if (status['running'] != true) throw StateError('Turn lost its running state');
      }
      stdout.writeln('${watch.elapsed.inSeconds}s: both turns still running; connection responsive.');
    }
    release.complete();
    await finished.future.timeout(const Duration(seconds: 15));
    if (terminals.any((event) => event['type'] != 'turn.completed' || event['seq'] is! int)) {
      throw StateError('Expected two durable completions: $terminals');
    }
    for (final id in ids) {
      final history = (await client.request('history.page', {'task_id': id}) as List).map(jsonObject).toList();
      if (history.last['type'] != 'turn.completed') throw StateError('Completion was not persisted');
    }
    final metrics = jsonObject(await client.request('telemetry'));
    if (metrics['active_tasks'] != 0 || metrics['resident_tasks'] != 0 || requests != 2) {
      throw StateError('Unexpected remaining work or provider retry');
    }
    stdout.writeln('PASS: two durable completions after ${watch.elapsed.inSeconds}s, no retries, all task owners released.');
  } finally {
    for (final pulse in pulses) {
      pulse.cancel();
    }
    if (!release.isCompleted) release.complete();
    await events?.cancel();
    await client?.close();
    await server?.close();
    for (final socket in sockets) {
      await socket.close();
    }
    await provider.close(force: true);
    await root.delete(recursive: true);
  }
}
