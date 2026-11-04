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
import 'package:test/test.dart';

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
  Future<Json> context(String id) async => jsonObject(await client.request('session.context', {'sessionID': id}));
  Future<List<Json>> usageRecords(String id) async => [for (final line in await rolloutLines(client, id))
    if (line['type'] == 'token_usage_record') jsonObject(line['payload'])];
  Future<void> launch({String transport = 'http', int? limit, int? headroom}) async {
    await File('${root.path}/config.yaml').writeAsString(jsonEncode({'providers': {'openai': {'settings': {
      'transport': transport, 'context_limit': ?limit, 'compaction_headroom': ?headroom,
    }}}}));
    server = await AgentServer.start(directory: root.path, port: 0, skillsHome: root.path,
      configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
    client = await AgentClient.connect(server.uri); subscription = client.events.stream.listen(events.add);
  }
  List<Json> reply(Json request) {
    requests.add(request);
    return requests.length <= scripts.length ? scripts[requests.length - 1] : [
      {'type': 'response.failed', 'response': {'error': {'code': 'invalid_prompt', 'message': 'Unexpected inference request'}}},
    ];
  }
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-incomplete-loop-');
    requests.clear(); events.clear(); sockets.clear(); scripts.clear();
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request); sockets.add(socket);
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

  for (final transport in ['http', 'websocket']) {
    for (final (name, usage) in [('usage', reported), ('missing_usage', null), ('malformed_usage', {'malformed': true})]) {
      test('incomplete_response_is_terminal: ${transport}_$name', () async {
        scripts.add([{'type': 'response.created'}, message('partial', 'Partial reply.'), incomplete('resp-incomplete', usage)]);
        await launch(transport: transport);
        final id = await createThread(client, {'cwd': root.path}), turn = await runTurn(client, id, prompt: 'trigger output limit');
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
      final id = await createThread(client, {'cwd': root.path}), turn = await runTurn(client, id, prompt: 'Give me both results.');
      expect(turn['status'], 'completed'); expect(turn['error'], isNull); expect(requests, hasLength(2));
      expect(jsonEncode(requests.last['input']), contains('The first result is ready.'));
      expect(events.where((event) => event['method'] == 'turn/started'), hasLength(1));
      expect(events.where((event) => event['method'] == 'turn/completed'), hasLength(1));
      expect(events.where((event) => event['method'] == 'happen/turn/retrying'), isEmpty);
      final page = jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
      expect(page['thread']['turns'], hasLength(1));
      expect((page['thread']['turns'][0]['items'] as List).where((item) => item['type'] == 'agentMessage').map((item) => item['text']),
        ['The first result is ready.', 'The second result is ready.']);
      expect(await usageRecords(id), isEmpty, reason: 'A nonterminal interrupt is ordinary sampling, not terminal spending.');
    });
  }

  for (final usage in [<String, Object?>{'input_tokens': 120000, 'output_tokens': 30000, 'total_tokens': 150000}, null]) {
    test('incomplete_response_during_compaction_is_terminal_and_counted: ${usage == null ? 'missing' : 'reported'}', () async {
      scripts.addAll([
        [message('initial', 'Initial reply.'), completed('initial', {'input_tokens': 120000, 'output_tokens': 0, 'total_tokens': 120000})],
        for (var i = 0; i < 2; i++) [message('discarded', 'DISCARDED_INCOMPLETE_SUMMARY'), incomplete('incomplete-compaction-$i', usage)],
      ]);
      await launch();
      final id = await createThread(client, {'cwd': root.path});
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
    final id = await createThread(client, {'cwd': root.path});
    expect((await runTurn(client, id, prompt: 'hello'))['status'], 'completed');
    expect((await runTurn(client, id, prompt: 'x' * 240000))['status'], 'failed');
    final records = await usageRecords(id);
    expect(records, hasLength(1)); expect(records.single['thread_token_usage']['total_tokens'], 140016);
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
      final id = await createThread(client, {'cwd': root.path});
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
      expect(records, hasLength(1)); expect(records.single['thread_token_usage']['total_tokens'], 53);
      expect(records.single['usage'], {'input_tokens': 7, 'cached_input_tokens': 1, 'cache_write_input_tokens': 0,
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
