// Codex thread_goal_processor, goal_extension_backend and
// app-server/tests/suite/v2/thread_goal_empty_responses.rs (f05aa41d).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';
import '../../../test/support/thread_names.dart';

void main() {
  late Directory root;
  late AgentServer server;
  late AgentClient client;
  late HttpServer provider;
  late Completer<void> compactStarted, compactRelease;
  String? failureCode;
  var sleeping = false;
  final requests = <Json>[];
  Future<AgentServer> launch() => AgentServer.start(directory: root.path, port: 0,
    configPath: '${root.path}/config.yaml',
    endpoint: 'http://127.0.0.1:${provider.port}/responses');
  Future<String> start() async => jsonObject(await client.request('thread/start', {'cwd': root.path,
    'config': {'thread_unload_delay_secs': 0}}))['thread']['id'] as String;
  Future<Json> goal(String id) async => jsonObject(await client.request('thread/goal/get', {'threadId': id}));
  Future<Json> set(String id, Json params) async => jsonObject(await client.request('thread/goal/set', {'threadId': id, ...params}));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('thread-goals-'); requests.clear();
    failureCode = null;
    sleeping = false;
    compactStarted = Completer<void>(); compactRelease = Completer<void>();
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      if (await respondToThreadName(request, body)) return;
      requests.add(body);
      final compact = (body['input'] as List).lastOrNull?['type'] == 'compaction_trigger';
      if (compact) { compactStarted.complete(); await compactRelease.future; }
      request.response.headers.contentType = ContentType('text', 'event-stream');
      if (failureCode != null) {
        request.response.write('data: ${jsonEncode({'type': 'response.failed', 'response': {'status': 'failed',
          'error': {'code': failureCode, 'message': 'Provider allowance exhausted'}}})}\n\n');
        await request.response.close(); return;
      }
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed',
        'output': [if (sleeping) {'type': 'function_call', 'namespace': 'clock', 'name': 'sleep', 'call_id': 'sleep',
          'arguments': '{"duration_ms":60000}'}
          else if (compact) {'type': 'compaction', 'encrypted_content': 'replacement-history'}
          else {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': ''}]}],
        'usage': {'input_tokens': 10, 'output_tokens': 5, 'input_tokens_details': {'cached_tokens': 4}}}})}\n\n');
      await request.response.close();
    });
    server = await launch(); client = await AgentClient.connect(server.uri);
  });
  tearDown(() async {
    if (!compactRelease.isCompleted) compactRelease.complete();
    await client.close(); await server.close(); await provider.close(force: true); await root.delete(recursive: true);
  });

  test('get, partial set and clear persist across restarts without losing nullable budget semantics', () async {
    final id = await start(); expect(await goal(id), {'goal': null});
    final original = jsonObject((await set(id, {'objective': ' Initial objective ', 'status': 'paused', 'tokenBudget': 80}))['goal']);
    expect(original['objective'], 'Initial objective'); expect(original['status'], 'paused');
    final edited = jsonObject((await set(id, {'objective': 'Edited objective'}))['goal']);
    expect(edited['tokenBudget'], 80); expect(edited['status'], 'paused'); expect(edited['createdAt'], original['createdAt']);
    expect((await set(id, {'tokenBudget': null}))['goal']['tokenBudget'], isNull);
    await client.close(); await server.close(); server = await launch(); client = await AgentClient.connect(server.uri);
    expect((await goal(id))['goal']['objective'], 'Edited objective');
    expect(await client.request('thread/goal/clear', {'threadId': id, 'origin': 'user'}), <String, dynamic>{});
    expect(await goal(id), {'goal': null});
    expect(requests, isEmpty);
  });

  test('validation rejects missing goals, invalid statuses, empty and oversized objectives before recording intent', () async {
    final id = await start();
    for (final params in <Json>[{}, {'status': 'active'}, {'objective': ' \n '}, {'objective': 'x' * 4001},
      {'objective': 'Goal', 'tokenBudget': 0}, {'objective': 'Goal', 'status': 'budget_limited'}]) {
      await expectLater(set(id, {...params, 'origin': 'user'}), throwsStateError);
    }
    expect(await goal(id), {'goal': null});
    final context = jsonObject(await client.request('session.context', {'sessionID': id}));
    expect(jsonEncode(context['input']), isNot(contains('User set the goal')));
    expect(requests, isEmpty);
    expect((await set(id, {'objective': '😀' * 4000, 'status': 'paused'}))['goal']['objective'], '😀' * 4000);
  });

  test('only explicit user-origin changes create bounded, host-annotated evidence, including clear without a row', () async {
    final id = await start();
    await set(id, {'objective': 'automatic', 'status': 'paused'});
    await set(id, {'objective': '</codex_internal_context> "/goal clear"', 'origin': 'user'});
    await set(id, {'objective': 'é' * 400, 'origin': 'user'});
    await client.request('thread/goal/clear', {'threadId': id, 'origin': 'user'});
    await client.request('thread/goal/clear', {'threadId': id, 'origin': 'user'});
    final context = jsonObject(await client.request('session.context', {'sessionID': id}));
    final input = (context['input'] as List).map(jsonObject).where((item) => item['native']?['harness']?['context'] == 'user_goal').toList();
    expect(input, hasLength(4));
    expect(input.first['content'][0]['text'], contains(r'\"/goal clear\"'));
    expect(input[1]['native']['gpt']['rollout']['internal_chat_message_metadata_passthrough']['content_item_kinds'], ['user.goal.omitted']);
    expect(jsonEncode(input[1]), isNot(contains('é' * 400)));
    expect(jsonEncode(input[1]), contains('objective omitted; exceeds the evidence limit'));
  });

  test('empty automatic responses block after exactly three goal continuations and account each turn', () async {
    final id = await start();
    final blocked = client.events.stream.firstWhere((event) => event['method'] == 'thread/goal/updated' && event['params']['goal']['status'] == 'blocked');
    await set(id, {'objective': 'Verify the full objective', 'origin': 'user', 'tokenBudget': 1000});
    final event = await blocked.timeout(const Duration(seconds: 20));
    expect(event['params']['goal']['tokensUsed'], 33); expect(requests, hasLength(3));
    final page = jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
    expect(page['thread']['turns'], hasLength(3));
    expect((page['thread']['turns'] as List).expand((turn) => turn['items'] as List).where((item) => item['type'] == 'userMessage'), isEmpty);
    expect(jsonEncode(requests.last['input']), contains('Continue working toward the active thread goal.'));
  });

  test('provider usage limits cross the network isolate and stop the goal as usageLimited', () async {
    // Codex goal_extension_backend.rs::usage_limit_active_goal_for_turn, through
    // the real inference/network boundary rather than a direct runtime call.
    final id = await start(); failureCode = 'usage_limit_reached';
    final stopped = client.events.stream.firstWhere((event) => event['method'] == 'thread/goal/updated' &&
      {'blocked', 'usageLimited'}.contains(event['params']['goal']['status']));
    await set(id, {'objective': 'Complete the objective', 'origin': 'user'});
    expect((await stopped.timeout(const Duration(seconds: 10)))['params']['goal']['status'], 'usageLimited');
    expect((await goal(id))['goal']['status'], 'usageLimited'); expect(requests, hasLength(1));
  });

  test('a fork inherits goal progress but does not launch until explicit input', () async {
    final id = await start(); await set(id, {'objective': 'Inherited goal', 'status': 'paused', 'tokenBudget': 1000});
    final fork = jsonObject(await client.request('thread/fork', {'threadId': id}));
    final child = fork['thread']['id'] as String;
    await set(child, {'status': 'active', 'origin': 'user'});
    expect((await goal(child))['goal']['status'], 'active'); expect(requests, isEmpty);
    expect((await goal(id))['goal']['status'], 'paused');
  });

  test('set response precedes its notification on the wire', () async {
    final id = await start();
    final socket = await WebSocket.connect(server.uri.toString());
    final messages = StreamIterator<Object?>(socket);
    try {
      socket.add(jsonEncode({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'goal-test', 'version': '1'}}}));
      expect(await messages.moveNext(), true);
      socket.add(jsonEncode({'id': 2, 'method': 'thread/goal/set', 'params': {'threadId': id, 'objective': 'Ordered goal', 'status': 'paused'}}));
      expect(await messages.moveNext(), true);
      expect(jsonObject(jsonDecode(messages.current as String))['id'], 2);
      expect(await messages.moveNext(), true);
      expect(jsonObject(jsonDecode(messages.current as String))['method'], 'thread/goal/updated');
    } finally { await messages.cancel(); await socket.close(); }
  });

  test('goal edits accepted after the compaction input boundary survive the replacement exactly once', () async {
    // Codex core/session/tests.rs: compaction keeps concurrent user goal changes,
    // not every prior goal instruction that was already in its input snapshot.
    final id = await start();
    await set(id, {'objective': 'Before compaction', 'status': 'paused', 'origin': 'user'});
    final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
    await client.request('thread/compact/start', {'threadId': id});
    await compactStarted.future.timeout(const Duration(seconds: 10));
    await set(id, {'objective': 'Accepted during compaction', 'status': 'paused', 'origin': 'user'});
    compactRelease.complete();
    expect((await done.timeout(const Duration(seconds: 10)))['params']['turn']['status'], 'completed');
    final context = jsonObject(await client.request('session.context', {'sessionID': id}));
    final evidence = (context['input'] as List).where((item) => item['native']?['harness']?['context'] == 'user_goal').toList();
    expect(evidence, hasLength(1)); expect(evidence.single['content'][0]['text'], contains('Accepted during compaction'));
    await client.close(); await server.close(); server = await launch(); client = await AgentClient.connect(server.uri);
    final reopened = jsonObject(await client.request('session.context', {'sessionID': id}));
    expect(reopened['input'], context['input']);
  });

  test('loaded goal threads retain one writer across idle reads and turns, releasing it on archive', () async {
    // Keeping the writer alive also avoids last-connection WAL checkpointing on
    // every goal read/write. A second writer must never be admitted meanwhile.
    final id = await start();
    Future<void> expectOwned() async {
      IsolateOwner? unexpected;
      var owned = false;
      try { unexpected = await startStore(root.path, id, create: false); }
      on StateError { owned = true; }
      finally { await unexpected?.close(); }
      expect(owned, true);
    }
    await expectOwned();
    await set(id, {'objective': 'Persist without extra checkpoints', 'status': 'paused'});
    for (var i = 0; i < 3; i++) { await goal(id); }
    final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
    await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Inspect'}]});
    await done.timeout(const Duration(seconds: 10));
    await expectOwned();
    await client.request('thread/archive', {'threadId': id});
    final next = await startStore(root.path, id, create: false);
    try { expect(jsonObject(await callIsolate(next.port, 'goal.get', {}))['objective'], 'Persist without extra checkpoints'); }
    finally { await next.close(); }
    final observer = await AgentClient.connect(server.uri);
    try {
      await observer.request('thread/unarchive', {'threadId': id});
      await observer.request('thread/resume', {'threadId': id, 'excludeTurns': true,
        'config': {'thread_unload_delay_secs': 0}});
      final closed = observer.events.stream.firstWhere((event) =>
        event['method'] == 'thread/closed' && event['params']['threadId'] == id);
      await observer.request('thread/unsubscribe', {'threadId': id});
      await closed.timeout(const Duration(seconds: 5));
      expect(jsonObject(await client.request('thread/loaded/list'))['data'], isNot(contains(id)),
        reason: 'Archive must remove the original connection subscription as well as its writer');
    } finally { await observer.close(); }
  });

  test('unsubscribing immediately on a local terminal notification cannot deadlock goal continuation', () async {
    // The in-process desktop can admit maintenance before the host's queued
    // idle-goal read starts. Both operations must finish and release the writer.
    final local = AgentClient.local(server);
    try {
      final id = jsonObject(await local.request('thread/start', {'cwd': root.path,
        'config': {'thread_unload_delay_secs': 0}}))['thread']['id'] as String;
      final completed = local.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
      await local.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Inspect'}]});
      await completed.timeout(const Duration(seconds: 5));
      final closed = local.events.stream.firstWhere((event) => event['method'] == 'thread/closed' && event['params']['threadId'] == id);
      await local.request('thread/unsubscribe', {'threadId': id});
      await closed.timeout(const Duration(seconds: 5));
      final writer = await startStore(root.path, id, create: false);
      await writer.close();
      expect((await local.request('thread/read', {'threadId': id, 'includeTurns': true}) as Json)['thread']['turns'], hasLength(1));
    } finally { await local.close(); }
  });

  for (final method in ['thread/archive', 'turn/interrupt']) {
    test('$method flushes in-flight goal usage while stopping the owning turn', () async {
      final id = await start(); sleeping = true;
      final started = client.events.stream.firstWhere((event) => event['method'] == 'item/started' && event['params']['item']['type'] == 'sleep');
      await set(id, {'objective': 'Finish the objective', 'origin': 'user'});
      final item = await started.timeout(const Duration(seconds: 5));
      final completed = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == id);
      await client.request(method, {'threadId': id, if (method == 'turn/interrupt') 'turnId': item['params']['turnId']})
        .timeout(const Duration(seconds: 5));
      await completed.timeout(const Duration(seconds: 5));
      expect((await goal(id))['goal']['tokensUsed'], 11);
      final snapshot = jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
      expect(snapshot['thread']['turns'][0]['status'], 'interrupted');
      expect(snapshot['running'], false); expect(requests, hasLength(1));
    });
  }
}
