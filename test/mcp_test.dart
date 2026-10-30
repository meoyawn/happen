import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('global stdio MCP shares a process, isolates cancellation, and supervises crashes', () async {
    final http = HttpClient();
    final events = StreamController<Json>.broadcast();
    final manager = McpManager(
      http: http,
      onEvent: (owner, event) => events.add({'owner': owner, ...event}),
    );
    final lifetime = CancellationToken();
    addTearDown(() async {
      lifetime.cancel();
      await manager.close();
      http.close(force: true);
      await events.close();
    });
    await manager.configure({
      'local': {
        'command': Platform.resolvedExecutable,
        'args': [File('test/fixtures/mcp_stdio.dart').absolute.path],
        'legacy_fallback': false,
      },
    }, lifetime);
    final initialPid = manager.status().single['pid'];
    expect(initialPid, isA<int>());
    expect(
      (await manager.catalog(lifetime))['tools'][0]['name'],
      'mcp__local__probe',
    );
    Future<Json> probe() async => jsonObject(
      jsonDecode(
        (await manager.callTool('mcp__local__probe', {
              'action': 'status',
            }, lifetime))['content'][0]['text']
            as String,
      ),
    );
    final waitingToken = CancellationToken();
    final waiting = expectLater(
      manager.callTool('mcp__local__probe', {'action': 'wait'}, waitingToken),
      throwsA(isA<CancelledException>()),
    );
    expect((await probe())['waiting'], 1);
    expect((await probe())['pid'], initialPid);
    final first = await manager.subscribe('first', {
      'server': 'local',
      'name': 'tick',
    }, lifetime);
    final second = await manager.subscribe('second', {
      'server': 'local',
      'name': 'tick',
    }, lifetime);
    expect((await probe())['streams'], 2);
    waitingToken.cancel();
    await waiting;
    await manager.unsubscribe('first', first['subscription_id'] as String);
    final tick = await events.stream
        .firstWhere(
          (event) =>
              event['owner'] == 'second' &&
              event['notification']['method'] == 'notifications/events/event',
        )
        .timeout(const Duration(seconds: 3));
    expect(tick['subscription_id'], second['subscription_id']);
    expect((await probe()), {'pid': initialPid, 'waiting': 0, 'streams': 1});
    await manager.detach('second');
    await expectLater(
      manager.callTool('mcp__local__probe', {'action': 'crash'}, lifetime),
      throwsA(isA<McpFailure>()),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (manager.status().single['pid'] == initialPid ||
        manager.status().single['state'] != 'ready') {
      if (DateTime.now().isAfter(deadline)) {
        fail('MCP subprocess did not restart');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect((await probe())['pid'], isNot(initialPid));
    expect((await probe())['waiting'], 0);
  });

  test('MCP HTTP events route push streams, resume cursors, poll, and authenticate webhooks', () async {
    final root = await Directory.systemTemp.createTemp('mcp-http-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final streams = <String, ({Json body, HttpResponse response})>{};
    final streamOpened = StreamController<String>.broadcast();
    final requests = <Json>[];
    Json? webhookRegistration;
    var polls = 0;
    Future<void> notify(
      String id,
      String method,
      Json data, {
      String? correlation,
    }) async {
      final response = streams[id]!.response;
      response.write(
        'data: ${jsonEncode({
          'jsonrpc': '2.0',
          'method': method,
          'params': {
            ...data,
            '_meta': {'io.modelcontextprotocol/subscriptionId': correlation ?? id},
          },
        })}\n\n',
      );
      await response.flush();
    }

    Json occurrence(String id, String cursor) => {
      'eventId': id,
      'name': 'changed',
      'timestamp': '2026-10-30T00:00:00Z',
      'data': {'value': id},
      'cursor': cursor,
    };
    upstream.listen((request) async {
      final payload = await utf8.decoder.bind(request).join();
      if (payload.isEmpty) {
        await request.response.close();
        return;
      }
      final body = jsonObject(jsonDecode(payload));
      requests.add(body);
      expect(request.headers.value('mcp-protocol-version'), '2026-07-28');
      expect(request.headers.value('mcp-method'), body['method']);
      expect(
        body['params']['_meta']['io.modelcontextprotocol/protocolVersion'],
        '2026-07-28',
      );
      final id = body['id'] as String;
      final params = jsonObject(body['params']);
      Object result;
      switch (body['method']) {
        case 'server/discover':
          result = {
            'supportedVersions': ['2026-07-28'],
            'capabilities': {'events': {}},
          };
        case 'events/list':
          result = {
            'events': [
              {
                'name': 'changed',
                'description': 'Fixture change',
                'inputSchema': {'type': 'object'},
                'payloadSchema': {'type': 'object'},
                'delivery': ['push', 'poll', 'webhook'],
              },
            ],
          };
        case 'events/stream':
          request.response.bufferOutput = false;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          streams[id] = (body: body, response: request.response);
          await notify(id, 'notifications/events/active', {
            'cursor': params['cursor'],
            'truncated': false,
          });
          streamOpened.add(id);
          return;
        case 'events/poll':
          polls++;
          result = {
            'events': polls == 1 ? [occurrence('polled', 'poll-1')] : [],
            'cursor': 'poll-$polls',
            'hasMore': polls == 1,
            'truncated': polls == 1,
            'nextPollMs': 60000,
          };
        case 'events/subscribe':
          webhookRegistration = params;
          result = {
            'id': 'webhook-peer-id',
            'cursor': 'webhook-0',
            'truncated': false,
            'refreshBefore': DateTime.now()
                .add(const Duration(minutes: 5))
                .toUtc()
                .toIso8601String(),
          };
        case 'events/unsubscribe':
          result = {};
        default:
          throw StateError('Unexpected MCP method ${body['method']}');
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      );
      await request.response.close();
    });
    await File('${root.path}/config.json').writeAsString(
      jsonEncode({
        'public_url': 'https://callback.example',
        'mcp_servers': {
          'remote': {
            'url': 'http://127.0.0.1:${upstream.port}/mcp',
            'legacy_fallback': false,
          },
        },
      }),
    );
    final server = await AgentServer.startEmbedded(
      directory: root.path,
      configPath: '${root.path}/config.yaml',
    );
    final client = await AgentClient.connect(server.uri);
    final received = <Json>[];
    final listener = client.events.stream.listen(received.add);
    final callbackHttp = HttpClient()..findProxy = (_) => 'DIRECT';
    callbackHttp.connectionFactory = (_, _, _) => Socket.startConnect(
      InternetAddress(server.socketPath!, type: InternetAddressType.unix),
      0,
    );
    addTearDown(() async {
      await client.close();
      await server.close();
      await listener.cancel();
      callbackHttp.close(force: true);
      for (final entry in streams.values) {
        unawaited(entry.response.close().catchError((Object _) {}));
      }
      await upstream.close(force: true);
      await streamOpened.close();
      await root.delete(recursive: true);
    });
    Future<Json> subscribe(String mode) async => jsonObject(
      await client
          .request('mcp.events.subscribe', {
            'server': 'remote',
            'name': 'changed',
            'mode': mode,
          })
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                throw StateError('Subscribe $mode did not activate'),
          ),
    );
    Future<Json> until(String method, [String? subscription]) => client
        .events
        .stream
        .firstWhere(
          (event) =>
              event['notification']?['method'] == method &&
              (subscription == null ||
                  event['subscription_id'] == subscription),
        )
        .timeout(const Duration(seconds: 5));
    final opened1 = streamOpened.stream.first;
    final first = await subscribe('push');
    final upstream1 = await opened1;
    final opened2 = streamOpened.stream.first;
    final second = await subscribe('push');
    final upstream2 = await opened2;
    final secondEvent = until(
      'notifications/events/event',
      second['subscription_id'] as String,
    );
    await notify(
      upstream1,
      'notifications/events/event',
      occurrence('wrong-stream', 'wrong'),
      correlation: upstream2,
    );
    await notify(
      upstream2,
      'notifications/events/event',
      occurrence('right-stream', 'cursor-1'),
    );
    expect(
      (await secondEvent)['notification']['params']['eventId'],
      'right-stream',
    );
    final gap = until(
      'notifications/events/active',
      second['subscription_id'] as String,
    );
    await notify(upstream2, 'notifications/events/active', {
      'cursor': 'gap-position',
      'truncated': true,
    });
    expect((await gap)['notification']['params']['truncated'], isTrue);
    await notify(
      upstream2,
      'notifications/events/event',
      occurrence('right-stream', 'cursor-1'),
    );
    final beat = until(
      'notifications/events/heartbeat',
      second['subscription_id'] as String,
    );
    await notify(upstream2, 'notifications/events/heartbeat', {
      'cursor': 'resume-position',
    });
    await beat;
    final reopened = streamOpened.stream.first;
    await streams[upstream2]!.response.close();
    final upstream3 = await reopened.timeout(const Duration(seconds: 5));
    expect(streams[upstream3]!.body['params']['cursor'], 'resume-position');
    await client.request('mcp.events.unsubscribe', {
      'subscription_id': first['subscription_id'],
    });
    final stillActive = until(
      'notifications/events/event',
      second['subscription_id'] as String,
    );
    await notify(
      upstream3,
      'notifications/events/event',
      occurrence('after-cancel', 'cursor-3'),
    );
    await stillActive;
    expect(
      received
          .where(
            (v) => v['notification']?['params']?['eventId'] == 'right-stream',
          )
          .length,
      1,
    );
    expect(
      received.any(
        (v) => v['notification']?['params']?['eventId'] == 'wrong-stream',
      ),
      isFalse,
    );
    final ended = until(
      'notifications/events/terminated',
      second['subscription_id'] as String,
    );
    await notify(upstream3, 'notifications/events/terminated', {
      'error': {'code': -32024, 'message': 'Forbidden'},
    });
    await ended;

    final polled = until('notifications/events/event');
    final polling = await subscribe('poll');
    expect((await polled)['notification']['params']['eventId'], 'polled');
    while (polls < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      requests
          .where((v) => v['method'] == 'events/poll')
          .last['params']['cursor'],
      'poll-1',
    );
    await client.request('mcp.events.unsubscribe', {
      'subscription_id': polling['subscription_id'],
    });
    final webhook = await subscribe('webhook');
    final secret = base64.decode(
      (webhookRegistration!['delivery']['secret'] as String).substring(6),
    );
    Future<(int, String)> deliver(
      Json value, {
      bool valid = true,
      int? stamp,
    }) async {
      final bytes = utf8.encode(jsonEncode(value));
      final id = value['eventId'] as String? ?? newId();
      final timestamp =
          '${stamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      final signature = base64.encode(
        Hmac(
          sha256,
          secret,
        ).convert([...utf8.encode('$id.$timestamp.'), ...bytes]).bytes,
      );
      final request = await callbackHttp.postUrl(
        Uri.parse('http://localhost/mcp-events/${webhook['subscription_id']}'),
      );
      request.headers.set('webhook-id', id);
      request.headers.set('webhook-timestamp', timestamp);
      request.headers.set(
        'webhook-signature',
        'v1,${valid ? signature : base64.encode(List.filled(32, 0))}',
      );
      request.headers.set('x-mcp-subscription-id', 'webhook-peer-id');
      request.add(bytes);
      final response = await request.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    }

    expect(
      (await deliver({'type': 'verification', 'challenge': 'prove-callback'}))
          .$2,
      contains('prove-callback'),
    );
    expect(
      (await deliver(occurrence('bad-signature', 'bad'), valid: false)).$1,
      401,
    );
    expect((await deliver(occurrence('stale', 'bad'), stamp: 1)).$1, 401);
    final delivered = until(
      'notifications/events/event',
      webhook['subscription_id'] as String,
    );
    expect((await deliver(occurrence('signed-event', 'webhook-1'))).$1, 200);
    await delivered;
    await deliver(occurrence('signed-event', 'webhook-1'));
    await client.request('mcp.events.unsubscribe', {
      'subscription_id': webhook['subscription_id'],
    });
    expect(
      requests.where((v) => v['method'] == 'events/unsubscribe').length,
      1,
    );
    expect(
      received
          .where(
            (v) => v['notification']?['params']?['eventId'] == 'signed-event',
          )
          .length,
      1,
    );
    expect(jsonEncode(received), isNot(contains('whsec_')));
    expect((await client.request('telemetry') as Map)['active_tasks'], 0);
  });
}
