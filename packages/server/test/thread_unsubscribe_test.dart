// Behavioral ports of Codex 5112ce6edeb9 app-server/tests/suite/v2/
// thread_unsubscribe.rs. Keep the full delay/ephemeral/source matrices.
// MCP Events draft wake-up is a Happen contract beyond Codex's forwarding-only test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import '../../../test/support/thread_names.dart';

void main() {
  late Directory root;
  late HttpServer upstream;
  late AgentServer server;
  late AgentClient client;
  late StreamSubscription<Json> listener;
  final received = <Json>[], requests = <Json>[];
  Json? registration;
  Json? polledEvent;
  ({HttpResponse response, String id})? eventStream;
  var failResponse = false;
  int? unloadDelay;
  Future<void> launch({int? delay}) async {
    unloadDelay = delay;
    await File('${root.path}/config.json').writeAsString(jsonEncode({
      'mcp_servers': {'comments': {'url': 'http://127.0.0.1:${upstream.port}/mcp', 'oauth': false, 'legacy_fallback': false}},
    }));
    server = await AgentServer.start(directory: root.path, port: 0, skillsHome: root.path,
      configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${upstream.port}/responses',
      publicUrl: 'https://callback.example');
    client = await AgentClient.connect(server.uri);
    listener = client.events.stream.listen(received.add);
  }
  Future<Json> request(String method, [Json params = const {}]) async => jsonObject(await client.request(method, params));
  Future<String> start([Json params = const {}]) async => (await request('thread/start', {'cwd': root.path,
    if (unloadDelay != null) 'config': {'thread_unload_delay_secs': unloadDelay}, ...params}))['thread']['id'] as String;
  Future<Json> notification(String method, String id) => client.events.stream.firstWhere((event) =>
    event['method'] == method && event['params']['threadId'] == id).timeout(const Duration(seconds: 10));
  Future<void> turn(String id, String text) async {
    final done = notification('turn/completed', id);
    await request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': text}]});
    expect((await done)['params']['turn']['status'], 'completed');
  }
  Future<void> noClose(String id, int milliseconds) async {
    final start = received.length;
    await Future<void>.delayed(Duration(milliseconds: milliseconds));
    expect(received.skip(start).where((event) => event['method'] == 'thread/closed' && event['params']['threadId'] == id), isEmpty);
  }
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-unsubscribe-');
    received.clear(); requests.clear(); registration = null; failResponse = false;
    polledEvent = null; eventStream = null;
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      if (await respondToThreadName(request, body)) return;
      if (request.uri.path == '/mcp') {
        expect(body['params'], isNot(contains('threadId')), reason: 'Thread ownership is local, not an MCP draft subscription parameter.');
        if (body['method'] == 'events/stream') {
          eventStream = (response: request.response, id: body['id'] as String);
          request.response.bufferOutput = false;
          request.response.headers.contentType = ContentType('text', 'event-stream');
          request.response.write('data: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/events/active',
            'params': {'cursor': null, 'truncated': false, '_meta': {'io.modelcontextprotocol/subscriptionId': body['id']}}})}\n\n');
          await request.response.flush(); return;
        }
        final result = switch (body['method']) {
          'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {'events': <String, Object?>{}}},
          'events/list' => {'events': [{'name': 'comment.created', 'description': 'Document comments', 'delivery': ['push', 'poll', 'webhook'],
            'inputSchema': {'type': 'object'}, 'payloadSchema': {'type': 'object'}}]},
          'events/poll' => {'events': [?polledEvent], 'cursor': null, 'truncated': false, 'hasMore': false, 'nextPollMs': 1000},
          'events/subscribe' => {'id': 'comments-subscription', 'cursor': null, 'truncated': false,
            'refreshBefore': DateTime.now().add(const Duration(minutes: 5)).toUtc().toIso8601String()},
          'events/unsubscribe' => <String, Object?>{},
          _ => throw StateError('Unexpected MCP method ${body['method']}'),
        };
        if (body['method'] == 'events/subscribe') registration = jsonObject(body['params']);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}));
      } else {
        requests.add(body);
        final input = body['input'] as List;
        final hasResult = input.any((item) => item['type'] == 'custom_tool_call_output' && item['call_id'] == 'deterministic-wait-call');
        request.response.headers.contentType = ContentType('text', 'event-stream');
        request.response.write('data: ${jsonEncode({'type': failResponse ? 'response.failed' : 'response.completed', 'response': {
          'id': 'response-${requests.length}', 'status': failResponse ? 'failed' : 'completed',
          if (failResponse) 'error': {'code': 'server_error', 'message': 'simulated failure'}
          else 'output': [if (jsonEncode(input).contains('run deterministic tool') && !hasResult)
            {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'deterministic-wait-call',
              'input': 'text(await tools.client__deterministic_wait({}));'}
            else {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Done'}]}],
        }})}\n\n');
      }
      try { await request.response.close(); } on IOException { /* Interrupted inference. */ }
    });
  });
  tearDown(() async {
    await client.close(); await server.close(); await listener.cancel();
    await upstream.close(force: true); await root.delete(recursive: true);
  });

  test('thread_unsubscribe_keeps_thread_loaded_until_idle_timeout', () async {
    await launch(delay: 2);
    final id = await start(); await turn(id, 'hello');
    expect(await request('thread/unsubscribe', {'threadId': id}), {'status': 'unsubscribed'});
    await noClose(id, 250);
    expect(await request('thread/loaded/list'), {'data': [id], 'nextCursor': null});
    expect((await request('thread/resume', {'threadId': id}))['thread']['id'], id);
    await noClose(id, 2200);
    final closed = notification('thread/closed', id);
    final status = client.events.stream.firstWhere((event) => event['method'] == 'thread/status/changed' &&
      event['params']['threadId'] == id && event['params']['status']['type'] == 'notLoaded');
    await request('thread/unsubscribe', {'threadId': id});
    await noClose(id, 250);
    expect((await closed)['params'], {'threadId': id});
    expect((await status.timeout(const Duration(seconds: 10)))['params'], {'threadId': id, 'status': {'type': 'notLoaded'}});
    expect(await request('thread/loaded/list'), {'data': <String>[], 'nextCursor': null});
    expect(await request('thread/unsubscribe', {'threadId': id}), {'status': 'notLoaded'});
    expect((await request('thread/read', {'threadId': id}))['thread']['status'], {'type': 'notLoaded'});
    expect((await request('thread/resume', {'threadId': id}))['thread']['status'], {'type': 'idle'});
  });

  for (final variant in [
    (name: 'zero_delay', delay: 0, expected: 0, params: <String, dynamic>{}),
    (name: 'one_second_delay', delay: 1, expected: 1, params: <String, dynamic>{}),
    (name: 'per_thread_one_second_delay', delay: 0, expected: 1,
      params: <String, dynamic>{'ephemeral': true, 'config': {'thread_unload_delay_secs': 1}}),
    (name: 'immediate_ephemeral', delay: 1800, expected: 0,
      params: <String, dynamic>{'ephemeral': true, 'config': {'thread_unload_delay_secs': 0}}),
    (name: 'immediate_persistent', delay: 1800, expected: 0,
      params: <String, dynamic>{'config': {'thread_unload_delay_secs': 0}}),
  ]) {
    test('thread_unsubscribe_during_turn_keeps_turn_running: ${variant.name}', () async {
      await launch(delay: variant.delay);
      final id = await start({...variant.params, 'dynamicTools': [{
        'name': 'deterministic_wait', 'description': 'Deterministic wait tool',
        'inputSchema': {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
      }]});
      await noClose(id, 250);
      final started = client.events.stream.firstWhere((event) => event['method'] == 'item/started' && event['params']['item']['id'] == 'deterministic-wait-call');
      // Happen currently transports client-owned dynamic calls as tools.call.
      final called = client.events.stream.firstWhere((event) => event['method'] == 'tools.call');
      await request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'run deterministic tool'}]});
      expect((await started.timeout(const Duration(seconds: 10)))['params']['threadId'], id);
      final call = await called.timeout(const Duration(seconds: 10));
      expect(call['params']['task_id'], id); expect(call['params']['tool'], 'deterministic_wait'); expect(call['params']['arguments'], <String, Object?>{});
      expect(await request('thread/unsubscribe', {'threadId': id}), {'status': 'unsubscribed'});
      await noClose(id, 1200);
      expect((await request('thread/loaded/list'))['data'], [id]);
      final closed = notification('thread/closed', id);
      client.socket!.add(jsonEncode({'id': call['id'], 'result': {'success': true, 'contentItems': [{'type': 'inputText', 'text': 'dynamic-ok'}]}}));
      if (variant.expected > 0) await noClose(id, 250);
      expect((await closed)['params'], {'threadId': id});
      expect(requests, hasLength(2), reason: 'Unsubscribe must not cancel the blocked call or its following inference.');
      if (variant.params['ephemeral'] == true) {
        expect(await Directory('${root.path}/tasks/$id').exists(), false);
        await expectLater(request('thread/resume', {'threadId': id}), throwsStateError);
      } else if (variant.params['config'] != null) {
        final resumed = await request('thread/resume', {'threadId': id});
        expect(resumed['thread']['id'], id); expect(resumed['thread']['turns'], hasLength(1));
        await request('thread/unsubscribe', {'threadId': id});
        await noClose(id, 250); // A cold resume uses the default delay, not the old override.
      }
    });
  }

  test('thread_unsubscribe_preserves_cached_status_before_idle_unload', () async {
    await launch(); failResponse = true;
    final id = await start(), failed = notification('turn/completed', id);
    await request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'fail this turn'}]});
    expect((await failed)['params']['turn']['status'], 'failed');
    expect((await request('thread/read', {'threadId': id}))['thread']['status'], {'type': 'systemError'});
    expect(await request('thread/unsubscribe', {'threadId': id}), {'status': 'unsubscribed'});
    await noClose(id, 250);
    expect((await request('thread/resume', {'threadId': id, 'cwd': root.path}))['thread']['status'], {'type': 'systemError'});
  });

  for (final variant in [
    (name: 'persistent', params: <String, dynamic>{}),
    (name: 'ephemeral', params: <String, dynamic>{'ephemeral': true}),
    (name: 'persistent_composer_prediction', params: <String, dynamic>{'threadSource': 'composer_predictions'}),
  ]) {
    test('thread_unsubscribe_reports_not_subscribed_before_idle_unload: ${variant.name}', () async {
      await launch(); final id = await start(variant.params);
      final thread = (await request('thread/read', {'threadId': id}))['thread'];
      expect(thread['ephemeral'], variant.params['ephemeral'] == true);
      if (variant.params['threadSource'] != null) expect(thread['threadSource'], 'composer_predictions');
      expect(await request('thread/unsubscribe', {'threadId': id}), {'status': 'unsubscribed'});
      expect(await request('thread/unsubscribe', {'threadId': id}), {'status': 'notSubscribed'});
      await noClose(id, 250);
    });
  }

  test('v2_child_idle_eviction_preserves_mail_and_followup_context', () {},
    skip: 'Codex MultiAgentV2 collaboration execution/mail/followup_task is not implemented; do not substitute a plain fork.');

  test('only losing the final subscriber or disconnecting starts idle unloading; read does not subscribe', () async {
    await launch(delay: 0);
    final id = await start(), observer = await AgentClient.connect(server.uri);
    try {
      await observer.request('thread/resume', {'threadId': id});
      await request('thread/unsubscribe', {'threadId': id});
      await noClose(id, 250);
      final closed = notification('thread/closed', id);
      await observer.close(); await closed;
      expect((await request('thread/read', {'threadId': id}))['thread']['status'], {'type': 'notLoaded'});
      expect((await request('thread/loaded/list'))['data'], isEmpty);
    } finally { await observer.close(); }
  });

  for (final mode in ['push', 'poll', 'webhook']) {
  for (final disconnect in [false, true]) {
    test('MCP $mode events wake an unloaded thread exactly once${disconnect ? ' after the subscribing client disconnects' : ''}', () async {
      await launch(delay: 0);
      final id = await start(); await turn(id, 'Watch document doc_123 and summarize new comments.');
      final unrelated = await start();
      final subscription = await request('mcp.events.subscribe', {'threadId': id, 'server': 'comments', 'name': 'comment.created',
        'arguments': {'document_id': 'doc_123'}, 'mode': mode});
      final http = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() => http.close(force: true));
      Future<int> webhook(Json event, {bool valid = true}) async {
        final bytes = utf8.encode(jsonEncode(event)), eventId = event['eventId'] as String? ?? 'verification';
        final stamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
        final secret = base64Decode((registration!['delivery']['secret'] as String).substring(6));
        final signature = base64Encode(Hmac(sha256, secret).convert([...utf8.encode('$eventId.$stamp.'), ...bytes]).bytes);
        final callback = await http.postUrl(Uri.parse('http://127.0.0.1:${server.http!.port}/mcp-events/${subscription['subscription_id']}'));
        callback.headers.set('webhook-id', eventId); callback.headers.set('webhook-timestamp', stamp);
        callback.headers.set('webhook-signature', 'v1,${valid ? signature : base64Encode(List.filled(32, 0))}');
        callback.headers.set('x-mcp-subscription-id', 'comments-subscription'); callback.add(bytes);
        final response = await callback.close(); await response.drain<void>(); return response.statusCode;
      }
      Future<void> deliver(Json event) async {
        switch (mode) {
          case 'webhook': expect(await webhook(event), 200);
          case 'poll': polledEvent = event;
          case 'push':
            eventStream!.response.write('data: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/events/event',
              'params': {...event, '_meta': {'io.modelcontextprotocol/subscriptionId': eventStream!.id}}})}\n\n');
            await eventStream!.response.flush();
        }
      }
      final closed = notification('thread/closed', id);
      await request('thread/unsubscribe', {'threadId': id}); await closed;
      if (disconnect) {
        await client.close(); await listener.cancel(); client = await AgentClient.connect(server.uri);
        listener = client.events.stream.listen(received.add);
      }
      expect((await request('thread/loaded/list'))['data'], isNot(contains(id)));
      final event = <String, dynamic>{'eventId': 'evt_456', 'name': 'comment.created', 'timestamp': '2026-11-05T12:05:00Z',
        'data': {'document_id': 'doc_123', 'comment_id': 'comment_456', 'text': 'Add rollout dates.', 'url': 'https://docs.example/doc_123#comment_456'}, 'cursor': null};
      if (mode == 'webhook') {
        expect(await webhook({'type': 'verification', 'challenge': 'prove-callback'}), 200);
        expect(await webhook(event, valid: false), 401);
      }
      await noClose(id, 100);
      expect((await request('thread/loaded/list'))['data'], isNot(contains(id)));
      expect(requests, hasLength(1), reason: 'Activation, callback verification and invalid signatures never wake a thread.');
      final completed = notification('turn/completed', id);
      await deliver(event);
      await completed;
      expect(requests, hasLength(2), reason: 'A valid event must cold-load and run the saved thread without a client resume.');
      final input = requests.last['input'] as List;
      expect(jsonEncode(input), contains('Watch document doc_123'));
      final delivered = input.where((item) => jsonEncode(item).contains('evt_456')).single;
      expect(delivered['role'], 'user', reason: 'Untrusted event payload must not gain developer/system authority.');
      expect(jsonEncode(delivered), contains('Add rollout dates.'));
      expect(jsonEncode(input), isNot(contains('whsec_')));
      await deliver(event);
      await Future<void>.delayed(Duration(milliseconds: mode == 'poll' ? 1250 : 250));
      expect(requests, hasLength(2));
      expect((await request('thread/read', {'threadId': id, 'includeTurns': true}))['thread']['turns'], hasLength(2));
      expect((await request('thread/read', {'threadId': unrelated, 'includeTurns': true}))['thread']['turns'], isEmpty);
      if (mode == 'webhook' && !disconnect) {
        // A 2xx is a receipt for durable admission, not just valid HMAC. Retry
        // the same event after inbox pressure clears; rejection must not poison
        // transport deduplication or interrupt the existing turn.
        await request('thread/resume', {'threadId': id});
        await request('tools.register', {'task_id': id, 'tools': [{'name': 'deterministic_wait',
          'description': 'Deterministic wait tool', 'inputSchema': {'type': 'object'}}]});
        final called = client.events.stream.firstWhere((event) => event['method'] == 'tools.call');
        await request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'run deterministic tool'}]});
        final call = await called.timeout(const Duration(seconds: 10));
        for (var i = 0; i < 32; i++) {
          await request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'queued $i'}]});
        }
        final retry = {...event, 'eventId': 'evt_retry'};
        expect(await webhook(retry), 503, reason: 'A full inbox must not acknowledge and lose an occurrence.');
        final pending = await request('session.inbox', {'sessionID': id});
        await client.request('session.inbox.cancel', {'sessionID': id, 'inboxID': 'msg_${pending['data'][0]['id']}'});
        expect(await webhook(retry), 200);
        expect(await webhook(retry), 200);
        final admitted = await request('session.inbox', {'sessionID': id});
        expect((admitted['data'] as List).where((input) => (input['prompt'] as String).contains('evt_retry')), hasLength(1));
        expect((await request('thread/read', {'threadId': id}))['running'], true);
        client.socket!.add(jsonEncode({'id': call['id'], 'result': {'success': true, 'contentItems': [{'type': 'inputText', 'text': 'dynamic-ok'}]}}));
      }
    });
  }
  }
}
