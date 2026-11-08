import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('MCP HTTP JSON and SSE preserve results above model output budgets', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final http = HttpClient();
    final manager = McpManager(http: http, onEvent: (_, _) {});
    final lifetime = CancellationToken();
    addTearDown(() async {
      lifetime.cancel();
      await manager.close();
      http.close(force: true);
      await upstream.close(force: true);
    });
    final large = 'é' * (2 * 1024 * 1024);
    upstream.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      final method = body['method'];
      final result = switch (method) {
        'server/discover' => {
          'supportedVersions': ['2026-07-28'],
          'capabilities': {'tools': <String, Object?>{}},
        },
        'tools/list' => {
          'tools': [
            {
              'name': 'large',
              'inputSchema': {
                'type': 'object',
                'properties': {'mode': {'type': 'string'}},
              },
            },
          ],
        },
        'tools/call' => {
          'content': [{'type': 'text', 'text': large}],
          'structuredContent': {'complete': true},
          'isError': false,
        },
        _ => <String, dynamic>{},
      };
      final response = jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result});
      if (body['params']['arguments']?['mode'] == 'sse') {
        request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write('data: $response\n\n');
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(response);
      }
      await request.response.close();
    });
    await manager.configure({
      'http': {
        'url': 'http://127.0.0.1:${upstream.port}/mcp',
        'legacy_fallback': false,
      },
    }, lifetime);
    for (final mode in ['json', 'sse']) {
      final result = await manager.callTool('mcp__http__large', {'mode': mode}, lifetime);
      expect(result['isError'], false);
      expect(result['content'][0]['text'] == large, isTrue, reason: mode);
      expect(result['structuredContent'], {'complete': true});
    }
  });

  test('global stdio MCP shares a process, isolates cancellation, and supervises crashes', () async {
    final root = await Directory.systemTemp.createTemp('mcp-event-registry-');
    final requestLog = File('${root.path}/requests');
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
      await root.delete(recursive: true);
    });
    await manager.configure({
      'local': {
        'command': Platform.resolvedExecutable,
        'args': [File('test/fixtures/mcp_stdio.dart').absolute.path],
        'env': {'MCP_REQUESTS_FILE': requestLog.path},
        'legacy_fallback': false,
      },
    }, lifetime);
    final initialPid = manager.status().single['pid'];
    expect(initialPid, isA<int>());
    final catalog = await manager.catalog(lifetime);
    expect(catalog['tools'][0]['name'], 'mcp__local__probe');
    expect(await manager.catalog(lifetime, knownRevision: catalog['revision'] as String),
      {'revision': catalog['revision'], 'unchanged': true});
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
    Future<void> discovered(int minimum) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while ((await requestLog.readAsLines()).where((line) => line == 'events/list').length < minimum) {
        if (DateTime.now().isAfter(deadline)) fail('Event catalog change was not rediscovered');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    final initialLists = (await requestLog.readAsLines()).where((line) => line == 'events/list').length;
    await manager.callTool('mcp__local__probe', {'action': 'event_catalog_changed'}, lifetime);
    await discovered(initialLists + 1);
    final recovered = events.stream.firstWhere((event) => event['owner'] == 'second' &&
      event['notification']['method'] == 'notifications/events/event' && event['notification']['params']['data']['revision'] == 3)
      .timeout(const Duration(seconds: 3));
    await manager.callTool('mcp__local__probe', {'action': 'event_schema_changed'}, lifetime);
    expect((await recovered)['subscription_id'], second['subscription_id']);
    await discovered(initialLists + 2);
    expect(manager.subscriptions('second').single['state'], 'active');
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
    final reconnected = await manager.catalog(lifetime, knownRevision: catalog['revision'] as String);
    expect(reconnected['revision'], isNot(catalog['revision']));
    expect(reconnected['tools'][0]['name'], 'mcp__local__probe');
    await manager.configure({}, lifetime);
    final removed = await manager.catalog(lifetime, knownRevision: reconnected['revision'] as String);
    expect(removed['tools'], isEmpty);
    expect(removed['revision'], isNot(reconnected['revision']));
  });

  test('MCP HTTP events route push streams, resume cursors, poll, and authenticate webhooks', () async {
    final root = await Directory.systemTemp.createTemp('mcp-http-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final streams = <String, ({Json body, HttpResponse response})>{};
    final streamOpened = StreamController<String>.broadcast();
    final requests = <Json>[];
    Json? webhookRegistration;
    var polls = 0;
    const forbidden = {'code': -32024, 'message': 'Forbidden', 'data': {'reason': 'Access revoked'}};
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
            'capabilities': {'events': <String, Object?>{}},
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
          if (polls == 2 || polls == 3) {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': polls == 2 ? {
              'code': -32026, 'message': 'Unsupported', 'data': {'feature': 'payloadSchema', 'reason': 'schema_changed'},
            } : forbidden}));
            await request.response.close();
            return;
          }
          result = {
            'events': polls == 1 ? [occurrence('polled', 'poll-1')] : <Object?>[],
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
      publicUrl: 'https://callback.example',
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
    Future<Json> subscribe(String? mode, {int ttlMs = 300000}) async => jsonObject(
      await client
          .request('mcp.events.subscribe', {
            'server': 'remote',
            'name': 'changed',
            if (mode != null) 'mode': mode,
            'ttl_ms': ttlMs,
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
    var upstream3 = await reopened.timeout(const Duration(seconds: 5));
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
    // The draft treats an omitted cursor exactly like null, including on
    // occurrences, activation/gap notices and quiet-period heartbeats.
    for (final kind in ['event', 'active', 'heartbeat']) {
      final positioned = until('notifications/events/heartbeat', second['subscription_id'] as String);
      await notify(upstream3, 'notifications/events/heartbeat', {'cursor': 'before-$kind'});
      await positioned;
      final cleared = until('notifications/events/$kind', second['subscription_id'] as String);
      final withoutCursor = kind == 'event'
          ? (occurrence('cursorless-$kind', 'unused')..remove('cursor'))
          : <String, dynamic>{};
      await notify(upstream3, 'notifications/events/$kind', withoutCursor);
      await cleared;
      final reconnect = streamOpened.stream.first;
      await streams[upstream3]!.response.close();
      upstream3 = await reconnect.timeout(const Duration(seconds: 5));
      expect(streams[upstream3]!.body['params']['cursor'], isNull, reason: kind);
    }
    final schemaReconnect = streamOpened.stream.first;
    final listsBeforeSchema = requests.where((value) => value['method'] == 'events/list').length;
    await notify(upstream3, 'notifications/events/terminated', {'error': {
      'code': -32026, 'message': 'Unsupported', 'data': {'feature': 'inputSchema', 'reason': 'schema_changed'},
    }});
    upstream3 = await schemaReconnect.timeout(const Duration(seconds: 5));
    expect(requests.where((value) => value['method'] == 'events/list').length, listsBeforeSchema + 1);
    final ended = until(
      'notifications/events/terminated',
      second['subscription_id'] as String,
    );
    await notify(upstream3, 'notifications/events/terminated', {
      'error': {'code': -32024, 'message': 'Forbidden'},
    });
    await ended;
    expect(await client.request('mcp.events.subscriptions'), isEmpty,
        reason: 'Provider termination removes the local subscription');

    final polled = until('notifications/events/event');
    final pollEnded = until('notifications/events/terminated');
    await subscribe('poll');
    expect((await polled)['notification']['params']['eventId'], 'polled');
    while (polls < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      requests
          .where((v) => v['method'] == 'events/poll')
          .last['params']['cursor'],
      'poll-1',
    );
    expect((await pollEnded)['notification']['params']['error'], forbidden);
    expect(await client.request('mcp.events.subscriptions'), isEmpty);
    final webhook = await subscribe(null, ttlMs: 1);
    expect(webhook['mode'], 'webhook', reason: 'A configured webhook takes precedence over push and poll');
    expect(webhookRegistration!['ttlMs'], 1, reason: 'The server clamps short suggestions to its own floor');
    final secret = base64.decode(
      (webhookRegistration!['delivery']['secret'] as String).substring(6),
    );
    Future<(int, String)> deliver(
      Json value, {
      bool valid = true,
      int? stamp,
      bool rotating = false,
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
        '${rotating ? 'v1,not-base64 v2,ignored ' : ''}v1,${valid ? signature : base64.encode(List.filled(32, 0))}',
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
    final cursorless = occurrence('rotated-signature', 'unused')..remove('cursor');
    expect((await deliver(cursorless, rotating: true)).$1, 200);
    final subscriptions = await client.request('mcp.events.subscriptions') as List;
    expect(subscriptions.singleWhere((dynamic value) => value['subscription_id'] == webhook['subscription_id'])['cursor'], isNull);
    final reactivated = until('notifications/events/active', webhook['subscription_id'] as String);
    final listsBeforeWebhookSchema = requests.where((value) => value['method'] == 'events/list').length;
    expect((await deliver({'type': 'terminated', 'error': {
      'code': -32026, 'message': 'Unsupported', 'data': {'feature': 'payloadSchema', 'reason': 'schema_changed'},
    }})).$1, 200);
    await reactivated;
    expect(requests.where((value) => value['method'] == 'events/list').length, listsBeforeWebhookSchema + 1);
    final afterSchema = until('notifications/events/event', webhook['subscription_id'] as String);
    expect((await deliver(occurrence('after-schema', 'webhook-2'))).$1, 200);
    await afterSchema;
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

  test('restoring a failed poll watch retains its saved ID and cursor without duplicating an active watch', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0), http = HttpClient();
    final token = CancellationToken(), events = <Json>[];
    var broken = true, polls = 0;
    final manager = McpManager(http: http, onEvent: (_, event) => events.add(event),
      persistSubscription: (_, _, _) async {}, acceptThreadEvent: (_, _) async {});
    addTearDown(() async { token.cancel(); await manager.close(); http.close(force: true); await upstream.close(force: true); });
    upstream.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      request.response.headers.contentType = ContentType.json;
      if (body['method'] == 'events/poll') {
        polls++;
        expect(body['params']['cursor'], 'saved-cursor');
        if (broken) {
          request.response.write(jsonEncode({'jsonrpc':'2.0','id':body['id'],'error':{'code':-32602,'message':'InvalidParams'}}));
          await request.response.close(); return;
        }
      }
      final result = switch (body['method']) {
        'server/discover' => {'supportedVersions':['2026-07-28'],'capabilities':{'events':<String,Object?>{}}},
        'events/list' => {'events':[{'name':'changed','delivery':['poll'],'inputSchema':{'type':'object'},'payloadSchema':{'type':'object'}}]},
        'events/poll' => {'events':<Object?>[],'cursor':'saved-cursor','nextPollMs':86400000,'hasMore':false,'truncated':false},
        _ => throw StateError('Unexpected MCP method ${body['method']}'),
      };
      request.response.write(jsonEncode({'jsonrpc':'2.0','id':body['id'],'result':result}));
      await request.response.close();
    });
    await manager.configure({'remote':{'url':'http://127.0.0.1:${upstream.port}/mcp','oauth':false}}, token);
    final snapshot = {'subscription_id':'b' * 32,'threadId':'saved','server':'remote','name':'changed',
      'mode':'poll','arguments':<String,Object?>{},'cursor':'saved-cursor'};
    await manager.restore('saved', [snapshot], token);
    expect(manager.subscriptions('thread:saved').single['state'], 'failed');
    broken = false;
    await manager.restore('saved', [snapshot], token);
    expect(manager.subscriptions('thread:saved').single, containsPair('state','active'));
    expect(manager.subscriptions('thread:saved').single['subscription_id'], snapshot['subscription_id']);
    await manager.restore('saved', [snapshot], token);
    expect(manager.subscriptions('thread:saved'), hasLength(1)); expect(polls, 2);
    expect(events.where((event) => event['notification']['method'] == 'notifications/events/event'), isEmpty);
  });

  test('restored webhook callbacks wait for a pending grant checkpoint without losing saved authority', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final http = HttpClient(), token = CancellationToken();
    final checkpoint = Completer<void>(), commit = Completer<void>(), admitted = <Json>[], notifications = <Json>[];
    final manager = McpManager(http: http, publicUrl: 'https://callback.example',
      onEvent: (_, event) => notifications.add(event),
      persistSubscription: (_, params, cancellation) async {
        if (params['snapshot']['upstream_id'] == 'renewed-registration') {
          if (!checkpoint.isCompleted) checkpoint.complete();
          await commit.future.asCancellable(cancellation);
        }
      }, acceptThreadEvent: (event, _) async { admitted.add(event); });
    addTearDown(() async {
      if (!commit.isCompleted) commit.complete();
      token.cancel(); await manager.close(); http.close(force: true); await upstream.close(force: true);
    });
    upstream.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      final result = switch (body['method']) {
        'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {'events': <String, Object?>{}}},
        'events/list' => {'events': [{'name': 'changed', 'delivery': ['webhook'], 'inputSchema': {'type': 'object'}, 'payloadSchema': {'type': 'object'}}]},
        'events/subscribe' => {'id': 'renewed-registration', 'refreshBefore': DateTime.now().add(const Duration(minutes: 5)).toUtc().toIso8601String()},
        'events/unsubscribe' => <String, Object?>{},
        _ => throw StateError('Unexpected MCP method ${body['method']}'),
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}));
      await request.response.close();
    });
    await manager.configure({'remote': {'url': 'http://127.0.0.1:${upstream.port}/mcp', 'oauth': false}}, token);
    final id = 'a' * 32, secret = List.filled(32, 7);
    final restoring = manager.restore('saved', [{'subscription_id': id, 'threadId': 'saved', 'server': 'remote',
      'name': 'changed', 'mode': 'webhook', 'arguments': <String, Object?>{}, 'cursor': 'saved-cursor',
      'callback': 'https://callback.example/mcp-events/$id', 'secret': base64Encode(secret), 'upstream_id': 'saved-registration'}], token);
    await checkpoint.future.timeout(const Duration(seconds: 5));
    expect(manager.subscriptions('thread:saved').single['state'], 'starting');
    final bytes = utf8.encode(jsonEncode({'eventId': 'during-commit', 'name': 'changed', 'data': <String, Object?>{},
      'timestamp': DateTime.now().toUtc().toIso8601String(), 'cursor': 'event-cursor'}));
    final stamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final signature = base64Encode(Hmac(sha256, secret).convert([...utf8.encode('during-commit.$stamp.'), ...bytes]).bytes);
    final callback = manager.webhook(id, {'webhook-id': 'during-commit', 'webhook-timestamp': stamp,
      'webhook-signature': 'v1,$signature', 'x-mcp-subscription-id': 'renewed-registration'}, bytes, token);
    expect(admitted, isEmpty);
    expect(notifications, isEmpty);
    commit.complete();
    final response = await callback;
    await restoring;
    expect(response['status'], 200);
    expect(admitted.single['notification']['params']['eventId'], 'during-commit');
    expect(manager.subscriptions('thread:saved').single['state'], 'active');
  });

  for (final (label, ttl, grant, valid) in [
    ('requested no expiry', null, 'none', true),
    ('finite grant instead of requested no expiry', null, 'finite', true),
    ('missing expiry grant', null, 'missing', false),
    ('unsolicited no expiry', 300000, 'none', false),
    ('expired grant', 300000, 'expired', false),
  ]) {
    test('MCP webhook $label is validated before activation', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final http = HttpClient(), token = CancellationToken(), notifications = <Json>[];
      final manager = McpManager(http: http, publicUrl: 'https://callback.example', onEvent: (_, event) => notifications.add(event));
      addTearDown(() async {
        token.cancel(); await manager.close(); http.close(force: true); await upstream.close(force: true);
      });
      upstream.listen((request) async {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        expect(request.headers.value('authorization'), 'Bearer test-principal');
        if (body['method'] == 'events/subscribe' && label == 'requested no expiry') {
          final delivery = jsonObject(body['params']['delivery']);
          final secret = base64Decode((delivery['secret'] as String).substring(6));
          final subscription = Uri.parse(delivery['url'] as String).pathSegments.last;
          Future<Json> deliver(String id, Json payload) {
            final bytes = utf8.encode(jsonEncode(payload)), stamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
            final signature = base64Encode(Hmac(sha256, secret).convert([...utf8.encode('$id.$stamp.'), ...bytes]).bytes);
            return manager.webhook(subscription, {
              'webhook-id': id, 'webhook-timestamp': stamp, 'webhook-signature': 'v1,$signature',
              'x-mcp-subscription-id': 'stable-subscription',
            }, bytes, token);
          }
          expect(await deliver('msg_verification_nonce', {'type': 'verification', 'challenge': 'nonce'}),
              {'status': 200, 'body': {'challenge': 'nonce'}});
          expect((await deliver('early-event', {'eventId': 'early-event', 'name': 'changed',
            'timestamp': DateTime.now().toUtc().toIso8601String(), 'data': <String, Object?>{}}))['status'], 503);
          expect(notifications, isEmpty, reason: 'A signed occurrence cannot bypass grant validation');
        }
        final result = switch (body['method']) {
          'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {'events': <String, Object?>{}}},
          'events/list' => {'events': [{'name': 'changed', 'delivery': ['webhook'], 'inputSchema': {'type': 'object'}, 'payloadSchema': {'type': 'object'}}]},
          'events/subscribe' => {
            'id': 'stable-subscription',
            if (grant != 'missing') 'refreshBefore': grant == 'none' ? null
                : DateTime.now().add(Duration(minutes: grant == 'expired' ? -5 : 5)).toUtc().toIso8601String(),
          },
          'events/unsubscribe' => <String, Object?>{},
          _ => throw StateError('Unexpected MCP method ${body['method']}'),
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}));
        await request.response.close();
      });
      await manager.configure({'remote': {'url': 'http://127.0.0.1:${upstream.port}/mcp', 'headers': {'Authorization': 'Bearer test-principal'}}}, token);
      final subscribing = manager.subscribe('owner', {'server': 'remote', 'name': 'changed', 'ttl_ms': ttl}, token);
      if (valid) {
        expect((await subscribing)['state'], 'active');
        expect(manager.subscriptions('owner').single['cursor'], isNull, reason: 'The grant may omit cursor');
      } else {
        await expectLater(subscribing, throwsA(isA<FormatException>()));
        expect(notifications, isEmpty, reason: 'An invalid grant must never advertise activation');
        expect(manager.subscriptions('owner'), isEmpty);
      }
    });
  }
}
