// Behavioral ports of Codex 5112ce6edeb9 core/tests/suite/client.rs::
// incomplete_response_is_terminal (all six transport/usage cases),
// incomplete_response_without_output_does_not_compact_the_next_turn, and
// compact.rs::incomplete_response_during_compaction_is_terminal_and_counted.
// Happen has no WebSocket prewarm or model-switch fallback: the same contracts
// run through its real inference/network/writer owners and public native API.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';
import '../../../test/support/thread_names.dart';

import '../../../test/support/thread.dart';

Json message(String id, String text) => {'type': 'response.output_item.done', 'item': {
  'id': id, 'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text}],
}};
Json completed(String id, Json usage) => {'type': 'response.completed', 'response': {'id': id, 'status': 'completed', 'usage': usage}};
Json incomplete(String id, Object? usage, {String reason = 'max_output_tokens'}) => {'type': 'response.incomplete', 'response': {
  'id': id, 'incomplete_details': {'reason': reason}, 'usage': usage,
}};
const reported = {'input_tokens': 120, 'output_tokens': 30, 'total_tokens': 150};
const recorded = {'input_tokens': 120, 'cached_input_tokens': 0, 'cache_write_input_tokens': 0,
  'output_tokens': 30, 'reasoning_output_tokens': 0, 'total_tokens': 150};

void main() {
  late Directory root;
  late HttpServer provider;
  late AgentServer server;
  late AgentClient client;
  late StreamSubscription<Json> subscription;
  final sockets = <WebSocket>[], requests = <Json>[], events = <Json>[], scripts = <List<Json>>[];
  final connections = <String, List<WebSocket>>{};
  Json threadSettings = {};
  Future<String> startThread() => createThread(client, {'cwd': root.path, 'settings': threadSettings});
  Future<Json> context(String id) async => jsonObject(await client.request('session.context', {'sessionID': id}));
  Future<List<Json>> usageRecords(String id) async => [for (final line in await rolloutLines(client, id))
    if (line['type'] == 'token_usage_record') jsonObject(line['payload'])];
  Future<void> launch({String transport = 'http', int? limit, int? headroom}) async {
    threadSettings = {
      'transport': transport, 'context_limit': ?limit, 'compaction_headroom': ?headroom,
    };
    server = await AgentServer.start(directory: root.path, port: 0, skillsHome: root.path,
      configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
    client = await AgentClient.connect(server.uri); subscription = client.events.stream.listen(events.add);
  }
  List<Json> reply(Json request) {
    if (threadNameReply(request) case final events?) return events;
    requests.add(request);
    return requests.length <= scripts.length ? scripts[requests.length - 1] : [
      {'type': 'response.failed', 'response': {'error': {'code': 'invalid_prompt', 'message': 'Unexpected inference request'}}},
    ];
  }
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-incomplete-loop-');
    requests.clear(); events.clear(); sockets.clear(); scripts.clear(); connections.clear();
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request); sockets.add(socket);
        (connections[request.headers.value('session-id')!] ??= []).add(socket);
        socket.listen((raw) {
          for (final event in reply(jsonObject(jsonDecode(raw as String)))) { socket.add(jsonEncode(event)); }
        });
      } else {
        final response = reply(jsonObject(jsonDecode(await utf8.decoder.bind(request).join())));
        request.response.headers.contentType = ContentType('text', 'event-stream');
        for (final event in response) { request.response.write('data: ${jsonEncode(event)}\n\n'); }
        await request.response.close();
      }
    });
  });
  tearDown(() async {
    await subscription.cancel(); await client.close(); await server.close();
    await Future.wait(sockets.map((socket) => socket.close()));
    await provider.close(force: true); await root.delete(recursive: true);
  });

  for (final release in ['unload', 'archive']) {
    test('WebSocket $release closes only its thread and resumes with full durable history', () async {
      scripts.addAll([for (var index = 1; index <= 5; index++) [
        message('message-$index', 'Reply $index'), completed('response-$index', reported),
      ]]);
      await launch(transport: 'websocket');
      final id = await createThread(client, {'cwd': root.path, 'settings': threadSettings,
        'config': {'thread_unload_delay_secs': 0}});
      final sibling = await startThread();
      for (final prompt in ['First turn', 'Second turn']) {
        expect((await runTurn(client, id, prompt: prompt))['status'], 'completed');
      }
      expect(connections[id], hasLength(1));
      expect(requests[1]['previous_response_id'], 'response-1');
      expect((await runTurn(client, sibling, prompt: 'Sibling turn'))['status'], 'completed');
      expect(connections[sibling], hasLength(1));
      final released = connections[id]!.single.done.timeout(const Duration(seconds: 5));
      if (release == 'unload') {
        await unloadThread(client, id);
      } else {
        await client.request('thread/archive', {'threadId': id});
      }
      await released;
      expect(connections[sibling]!.single.readyState, WebSocket.open, reason: 'Sibling inference must retain its connection.');
      if (release == 'archive') await client.request('thread/unarchive', {'threadId': id});
      await client.request('thread/resume', {'threadId': id});
      expect((await runTurn(client, id, prompt: 'Resumed turn'))['status'], 'completed');
      expect(connections[id], hasLength(2));
      expect(requests[3].containsKey('previous_response_id'), isFalse);
      final restored = jsonEncode(requests[3]['input']);
      for (final text in ['First turn', 'Second turn', 'Reply 1', 'Reply 2', 'Resumed turn']) {
        expect(restored, contains(text));
      }
      expect((await runTurn(client, sibling, prompt: 'Sibling continuation'))['status'], 'completed');
      expect(connections[sibling], hasLength(1));
      expect(requests.last['previous_response_id'], 'response-3');
      for (final entry in connections.entries.where((entry) => !{id, sibling}.contains(entry.key))) {
        await Future.wait(entry.value.map((socket) => socket.done)).timeout(const Duration(seconds: 5));
      }
    });
  }

  test('retry removes a retired saved setting and retains the failed turn context across restart', () async {
    scripts.addAll([
      [incomplete('failed', reported)],
      [message('recovered', 'Resumed the saved conversation.'), completed('recovered', reported)],
    ]);
    await launch();
    final id = await startThread();
    final failed = await runTurn(client, id, prompt: 'Keep this request when retrying.');
    expect(failed['status'], 'failed');
    final before = await contextItems(client, id);
    final original = jsonObject(threadMetadata(root.path, id, 'config'));
    await subscription.cancel(); await client.close(); await server.close();
    // Model a thread written before this provider option was removed. No live
    // writer exists while seeding its original on-disk configuration.
    final stored = TaskStore(root.path, id, create: false);
    try {
      stored.db.execute('UPDATE metadata SET value = ? WHERE key IS ?', [jsonEncode({
        ...original, 'provider_settings': {...jsonObject(original['provider_settings']), 'standalone_web_search': false},
      }), 'config']);
    } finally { stored.close(); }
    await launch();
    final resumed = await runTurn(client, id, settings: {'input': <Json>[], 'expectedTurnId': failed['id']});
    expect(resumed['status'], 'completed', reason: '${resumed['error']}');
    expect(requests, hasLength(2));
    expect(jsonEncode(requests.last['input']), contains('Keep this request when retrying.'));
    expect((await contextItems(client, id)).take(before.length), before);
    expect(threadMetadata(root.path, id, 'config'), original);
  });

  // Complete ordinary token_usage_rollout.rs matrix; a pure cell replaces
  // upstream's plan tool without supplying accounting or persistence itself.
  for (final transport in ['http', 'websocket']) {
    test('observed response usage accumulates by turn/thread across restart: $transport', () async {
      Json usage(int total) => {'input_tokens': total - 10, 'output_tokens': 10, 'total_tokens': total};
      scripts.addAll([
        [{'type': 'response.completed', 'response': {'id': 'response-a', 'status': 'completed', 'usage': usage(120), 'output': [
          {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'cell-a', 'input': 'text(1);'},
        ]}}],
        [message('message-b', 'done'), completed('response-b', usage(80))],
        [message('message-c', 'next'), completed('response-c', usage(30))],
        [message('message-d', 'no usage'), {'type': 'response.completed', 'response': {'id': 'response-without-usage', 'status': 'completed'}}],
      ]);
      await launch(transport: transport);
      final id = await startThread(), first = await runTurn(client, id, prompt: 'first');
      expect(first['status'], 'completed');
      expect(first['tokenUsage'], containsPair('input_tokens', 180));
      expect(first['tokenUsage'], containsPair('output_tokens', 20));
      expect(first['durationMs'], isA<int>().having((value) => value, 'elapsed milliseconds', greaterThanOrEqualTo(0)));
      await subscription.cancel(); await client.close(); await server.close(); await launch(transport: transport);
      final second = await runTurn(client, id, prompt: 'second'); await runTurn(client, id, prompt: 'third');
      expect(second['tokenUsage'], containsPair('input_tokens', 20));
      expect(second['tokenUsage'], containsPair('output_tokens', 10));
      final records = await usageRecords(id);
      expect(records.map((record) => [record['response_id'], record['turn_token_usage']['total_tokens'], record['thread_token_usage']['total_tokens']]), [
        ['response-a', 120, 120], ['response-b', 200, 200], ['response-c', 30, 230],
      ]);
      expect(records.map((r) => r['turn_id']), [first['id'], first['id'], second['id']]);
      expect(records.map((r) => r['session_id']), everyElement(id));
      expect(records.every((r) => r['thread_id'] == id && r['root_turn_id'] == r['turn_id']), true);
    });

    for (final total in [0, 25]) {
      test('manual compaction checkpoints real spending, not the local estimate: $transport/$total', () async {
        scripts.addAll([
          [message('initial', 'Before compaction'), completed('initial', {'input_tokens': 990, 'output_tokens': 10, 'total_tokens': 1000})],
          [{'type': 'response.completed', 'response': {'id': 'compact', 'status': 'completed',
            'usage': {'input_tokens': total, 'output_tokens': 0, 'total_tokens': total},
            'output': [{'type': 'compaction', 'id': 'checkpoint', 'encrypted_content': 'opaque-checkpoint'}]}}],
          [message('after', 'After compaction'), completed('after', {'input_tokens': 9, 'output_tokens': 1, 'total_tokens': 10})],
        ]);
        await launch(transport: transport);
        final id = await startThread(); await runTurn(client, id, prompt: 'Keep the fact.');
        expect((await runTurn(client, id, compact: true))['status'], 'completed');
        final before = await usageRecords(id), rollout = await rolloutLines(client, id);
        expect(before.map((r) => r['usage']['total_tokens']), [1000, total]);
        final checkpoint = rollout.singleWhere((line) => line['type'] == 'compacted')['payload'];
        expect(checkpoint['compaction_response_id'], 'compact'); expect(checkpoint['latest_token_usage_record'], before.last);
        expect(threadMetadata(root.path, id, 'context_usage'), isA<int>().having((value) => value, 'local estimate', greaterThan(0)));
        await subscription.cancel(); await client.close(); await server.close(); await launch(transport: transport);
        await runTurn(client, id, prompt: 'Continue.');
        final after = await usageRecords(id); expect(after.last['thread_token_usage']['total_tokens'], 1010 + total);
        expect(after.last['turn_token_usage']['total_tokens'], 10);
      });
    }
  }

  for (final transport in ['http', 'websocket']) {
    for (final (name, usage) in [('usage', reported), ('missing_usage', null), ('malformed_usage', {'malformed': true})]) {
      test('incomplete_response_is_terminal: ${transport}_$name', () async {
        scripts.add([{'type': 'response.created'}, message('partial', 'Partial reply.'), incomplete('resp-incomplete', usage)]);
        await launch(transport: transport);
        final id = await startThread(), turn = await runTurn(client, id, prompt: 'trigger output limit');
        expect(turn['status'], 'failed'); expect(requests, hasLength(1));
        expect(events.where((event) => event['method'] == 'happen/turn/retrying'), isEmpty);
        final records = await usageRecords(id);
        if (name == 'usage') {
          expect(records, hasLength(1), reason: 'Reported spending must survive a terminal inference failure.');
          expect(records.single['response_id'], 'resp-incomplete'); expect(records.single['usage'], recorded);
          expect(records.single['thread_id'], id); expect(records.single['turn_id'], turn['id']);
          expect(records.single['turn_token_usage'], recorded); expect(records.single['thread_token_usage'], recorded);
          expect(events.where((event) => event['method'] == 'thread/tokenUsage/updated'), hasLength(1));
        } else {
          expect(records, isEmpty, reason: 'Missing/malformed usage must not be estimated or invented.');
          expect(events.where((event) => event['method'] == 'thread/tokenUsage/updated'), isEmpty);
        }
        expect(turn['error']['message'], contains('Incomplete response returned, reason: max_output_tokens'));
        final snapshot = await context(id);
        expect(jsonEncode(snapshot['input']), contains('Partial reply.'));
        expect(snapshot['tokens'], isNull, reason: 'Terminal spending must not become the context baseline.');
      });
    }
  }

  // codex-api/src/sse/responses.rs maps the explicit "interrupted" reason
  // to Completed { end_turn: false }, unlike terminal incomplete failures.
  for (final transport in ['http', 'websocket']) {
    test('interrupted incomplete responses continue sampling in the same turn: $transport', () async {
      scripts.addAll([
        [message('fragment', 'The first result is ready.'), incomplete('interrupted', reported, reason: 'interrupted')],
        [message('answer', 'The second result is ready.'), completed('answer', {'input_tokens': 10, 'output_tokens': 1, 'total_tokens': 11})],
      ]);
      await launch(transport: transport);
      final id = await startThread(), turn = await runTurn(client, id, prompt: 'Give me both results.');
      expect(turn['status'], 'completed'); expect(turn['error'], isNull); expect(requests, hasLength(2));
      expect(jsonEncode(requests.last['input']), contains('The first result is ready.'));
      expect(events.where((event) => event['method'] == 'turn/started'), hasLength(1));
      expect(events.where((event) => event['method'] == 'turn/completed'), hasLength(1));
      expect(events.where((event) => event['method'] == 'happen/turn/retrying'), isEmpty);
      final page = jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
      expect(page['thread']['turns'], hasLength(1));
      expect((page['thread']['turns'][0]['items'] as List).where((item) => item['type'] == 'agentMessage').map((item) => item['text']),
        ['The first result is ready.', 'The second result is ready.']);
      final receipts = await usageRecords(id);
      expect(receipts.map((r) => [r['response_id'], r['turn_token_usage']['total_tokens'], r['thread_token_usage']['total_tokens']]),
        [['interrupted', 150, 150], ['answer', 161, 161]], reason: 'A nonterminal interrupt records ordinary sampling exactly once and continues the same turn.');
      expect(receipts.map((r) => r['turn_id']), everyElement(turn['id']));
    });
  }

  for (final usage in [<String, Object?>{'input_tokens': 120000, 'output_tokens': 30000, 'total_tokens': 150000}, null]) {
    test('incomplete_response_during_compaction_is_terminal_and_counted: ${usage == null ? 'missing' : 'reported'}', () async {
      scripts.addAll([
        [message('initial', 'Initial reply.'), completed('initial', {'input_tokens': 120000, 'output_tokens': 0, 'total_tokens': 120000})],
        for (var i = 0; i < 2; i++) [message('discarded', 'DISCARDED_INCOMPLETE_SUMMARY'), incomplete('incomplete-compaction-$i', usage)],
      ]);
      await launch();
      final id = await startThread();
      expect((await runTurn(client, id, prompt: 'x' * 440000))['status'], 'completed');
      final before = await context(id);
      for (var i = 0; i < 2; i++) {
        final turn = await runTurn(client, id, compact: true);
        expect(turn['status'], 'failed'); expect(turn['error']['message'], contains('Incomplete response returned, reason: max_output_tokens'));
        final after = await context(id);
        expect(after['input'], before['input']); expect(after['tokens'], before['tokens']);
        final records = (await usageRecords(id)).where((record) => (record['response_id'] as String).startsWith('incomplete-compaction')).toList();
        expect(records, hasLength(usage == null ? 0 : i + 1));
        if (usage != null) {
          expect(records.last['usage']['total_tokens'], 150000);
          expect(records.last['thread_token_usage']['total_tokens'], 120000 + 150000 * (i + 1));
        }
      }
      expect(requests, hasLength(3));
      expect(requests.skip(1).map((request) => (request['input'] as List).last['type']), everyElement('compaction_trigger'));
      expect(jsonEncode(requests.last['input']), isNot(contains('DISCARDED_INCOMPLETE_SUMMARY')));
      expect((await rolloutLines(client, id)).where((line) => line['type'] == 'compacted'), isEmpty);
      expect(events.where((event) => event['method'] == 'happen/turn/retrying'), isEmpty);
    });
  }

  test('incomplete_response_without_output_does_not_compact_the_next_turn', () async {
    scripts.addAll([
      [message('initial', 'Initial reply.'), completed('initial', {'input_tokens': 40000, 'output_tokens': 0, 'total_tokens': 40000})],
      [incomplete('incomplete', {'input_tokens': 100000, 'output_tokens': 16, 'total_tokens': 100016})],
      [message('continued', 'Continued.'), completed('continued', {})],
    ]);
    await launch(limit: 148000, headroom: 20000);
    final id = await startThread();
    expect((await runTurn(client, id, prompt: 'hello'))['status'], 'completed');
    expect((await runTurn(client, id, prompt: 'x' * 240000))['status'], 'failed');
    final records = await usageRecords(id);
    expect(records.map((r) => [r['response_id'], r['thread_token_usage']['total_tokens']]), [['initial', 40000], ['incomplete', 140016]]);
    expect((await runTurn(client, id, prompt: 'continue'))['status'], 'completed');
    expect(requests, hasLength(3));
    expect(requests.expand((request) => request['input'] as List).where((item) => item['type'] == 'compaction_trigger'), isEmpty);
    expect(events.where((event) => event['method'] == 'item/started' && event['params']['item']['type'] == 'contextCompaction'), isEmpty);
  });

  // session/tests.rs::record_token_usage_info_notifies_extension_contributors:
  // SpendingOnly reaches the real goal contributor without replacing the last
  // sampling baseline. Also retain turn.rs's original error if accounting
  // exhausts the goal's budget.
  for (final budget in [1000, 40]) {
    test('terminal spending reaches goal accounting and preserves the error: budget $budget', () async {
      scripts.addAll([
        [message('initial', 'Progress.'), completed('initial', {'input_tokens': 10, 'input_tokens_details': {'cached_tokens': 2},
          'output_tokens': 20, 'output_tokens_details': {'reasoning_tokens': 3}, 'total_tokens': 33})],
        [incomplete('incomplete', {'input_tokens': 7, 'input_tokens_details': {'cached_tokens': 1},
          'output_tokens': 8, 'output_tokens_details': {'reasoning_tokens': 5}, 'total_tokens': 20})],
      ]);
      await launch();
      final id = await startThread();
      final stopped = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' &&
        event['params']['threadId'] == id && event['params']['turn']['status'] == 'failed');
      await client.request('thread/goal/set', {'threadId': id, 'objective': 'Finish the work', 'tokenBudget': budget, 'origin': 'user'});
      final turn = jsonObject((await stopped.timeout(const Duration(seconds: 15)))['params']['turn']);
      expect(turn['error']['message'], contains('Incomplete response returned, reason: max_output_tokens'));
      expect(requests, hasLength(2));
      final goal = jsonObject(await client.request('thread/goal/get', {'threadId': id}));
      expect(goal['goal']['tokensUsed'], 42);
      expect(goal['goal']['status'], budget == 40 ? 'budgetLimited' : 'blocked');
      final records = await usageRecords(id);
      expect(records.map((r) => [r['response_id'], r['thread_token_usage']['total_tokens']]), [['initial', 33], ['incomplete', 53]]);
      expect(records.last['usage'], {'input_tokens': 7, 'cached_input_tokens': 1, 'cache_write_input_tokens': 0,
        'output_tokens': 8, 'reasoning_output_tokens': 5, 'total_tokens': 20});
      final before = await context(id);
      expect(before['tokens'], {'input': 8, 'output': 17, 'reasoning': 3, 'cache': {'read': 2, 'write': 0}});
      await subscription.cancel(); await client.close(); await server.close(); await launch();
      expect((await context(id))['tokens'], before['tokens']);
      expect(await usageRecords(id), records);
      expect(jsonObject(await client.request('thread/goal/get', {'threadId': id})), goal);
      expect(requests, hasLength(2));
    });
  }
}
