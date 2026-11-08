// Behavioral ports of Codex app-server/tests/suite/v2/thread_fork.rs.
// SQLite lineage/storage invariants are owned by storage's lifecycle tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/agent.dart';
import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, other;
  late AgentServer server;
  late AgentClient client, observer;
  late HttpServer provider;
  final requests = <Json>[];
  final events = <Json>[];
  late StreamSubscription<Json> subscription;
  late Completer<void> held, release;
  const firstUsage = {'input_tokens': 120, 'output_tokens': 30, 'cached_input_tokens': 20, 'reasoning_tokens': 10};

  Future<Json> read(String id) async => jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
  Future<Json> fork([Json params = const {}]) async =>
    jsonObject(await client.request('thread/fork', {'threadId': 'parent', ...params}));
  List<String> turnIds(Json page) => (page['thread']['turns'] as List).map((turn) => turn['id'] as String).toList();
  Future<void> turn(String id, String text) async {
    final completed = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == id);
    await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': text}]});
    final result = await completed.timeout(const Duration(seconds: 15));
    expect(result['params']['turn']['status'], 'completed', reason: jsonEncode(result));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('thread-fork-');
    other = await Directory('${root.path}/other').create();
    requests.clear(); events.clear(); held = Completer<void>(); release = Completer<void>();
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    final config = initialConfiguration({'provider': 'openai', 'model': 'gpt-6.1-sol', 'global_directory': root.path,
      'provider_settings': {'reasoning': 'medium', 'transport': 'http', 'context_limit': 200000, 'compaction_headroom': 32000},
      'instructions': 'You are a helpful assistant.', 'developerInstructions': 'Keep the inherited policy.'}, root.path, false);
    final store = TaskStore(root.path, 'parent');
    try {
      store.append('task.created', config, metadata: {'config': config, 'effective_reasoning': 'high'});
      for (final id in ['one', 'two', 'three']) {
        store.append('turn.started', {'turnId': id});
        store.append('input.committed', {'message_id': 'input-$id', 'item': ConversationItem.user('Question $id').toJson()});
        store.append('model.completed', {'assistantMessageID': 'answer-$id',
          'output': [ConversationItem.text('assistant', 'Answer $id').toJson()],
          'usage': id == 'one' ? firstUsage : {'input_tokens': 500, 'output_tokens': 50}});
        store.append('turn.completed', {});
      }
    } finally { store.close(); }
    final token = CancellationToken(), catalog = await startServerStore(root.path, cancellation: token);
    try {
      final writer = await startStore(root.path, 'parent', create: false, catalog: catalog.port, cancellation: token);
      await writer.close();
    } finally { await catalog.close(); token.cancel(); }
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requests.add(body);
      if (body['tool_choice'] != 'none' && jsonEncode(body['input']).contains('Hold the parent')) {
        held.complete();
        await release.future;
      }
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed',
        'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Independent answer.'}]}],
        'usage': {'input_tokens': 10, 'output_tokens': 5}}})}\n\n');
      await request.response.close();
    });
    server = await AgentServer.start(directory: root.path, port: 0, skillsHome: root.path,
      configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
    client = await AgentClient.connect(server.uri);
    observer = await AgentClient.connect(server.uri);
    subscription = observer.events.stream.listen(events.add);
  });

  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await subscription.cancel();
    await observer.close(); await client.close(); await server.close();
    await provider.close(force: true); await root.delete(recursive: true);
  });

  test('fork response precedes restored usage and the global metadata-only started event', () async {
    final socket = await WebSocket.connect(server.uri.toString());
    final messages = StreamIterator<Object?>(socket);
    Future<Json> next() async {
      expect(await messages.moveNext().timeout(const Duration(seconds: 10)), true);
      return jsonObject(jsonDecode(messages.current as String));
    }
    try {
      socket.add(jsonEncode({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'fork-test', 'version': '1'}}}));
      expect((await next())['id'], 1);
      socket.add(jsonEncode({'id': 2, 'method': 'thread/fork', 'params': {'threadId': 'parent', 'lastTurnId': 'one', 'threadSource': 'user'}}));
      final response = await next();
      expect(response['id'], 2, reason: 'A new fork must be introduced by its response, without a preceding status event.');
      final page = jsonObject(response['result']), child = page['thread']['id'] as String;
      expect(page['thread']['sessionId'], child);
      expect(page['thread']['forkedFromId'], 'parent');
      expect(page['thread']['name'], isNull);
      expect(page['thread']['threadSource'], 'user');
      expect(page['thread']['status'], {'type': 'idle'});
      expect(page['model'], 'gpt-6.1-sol'); expect(page['modelProvider'], 'openai');
      expect(page['cwd'], root.path); expect(page['reasoningEffort'], 'high');
      expect(turnIds(page), ['one']);
      final usage = await next();
      expect(usage['method'], 'thread/tokenUsage/updated');
      expect(usage['params']['threadId'], child); expect(usage['params']['turnId'], 'one');
      expect(usage['params']['tokenUsage'], firstUsage);
      final started = await next();
      expect(started['method'], 'thread/started');
      expect(started['params']['thread'], {...jsonObject(page['thread']), 'turns': <Json>[]});
      await observer.request('thread/loaded/list');
      expect(events.where((event) => event['method'] == 'thread/started').single['params']['thread']['id'], child);
      expect(events.where((event) => event['method'] == 'thread/status/changed' || event['method'] == 'thread/tokenUsage/updated'), isEmpty);
    } finally { await messages.cancel(); await socket.close(); }
  });

  test('saved names and effective settings are inherited, and fork overrides stay private', () async {
    await client.request('thread/name/set', {'threadId': 'parent', 'name': 'Chosen source name'});
    final page = await fork({'model': 'gpt-6-astra', 'modelProvider': 'openai', 'cwd': other.path,
      'reasoning': 'low', 'developerInstructions': 'Use the fork policy.', 'excludeTurns': true});
    final child = page['thread']['id'] as String;
    expect(page['thread']['name'], 'Chosen source name');
    expect(page['thread']['turns'], isEmpty);
    expect(page['model'], 'gpt-6-astra'); expect(page['cwd'], other.path); expect(page['reasoningEffort'], 'low');
    await client.request('thread/name/set', {'threadId': child, 'name': 'Child name'});
    expect((await read('parent'))['thread']['name'], 'Chosen source name');
    await turn(child, 'Continue the child');
    final request = requests.last;
    expect(request['model'], 'gpt-6-astra'); expect(request['reasoning']['effort'], 'low');
    expect(jsonEncode(request), contains('Use the fork policy.'));
    final parent = await read('parent');
    expect(parent['configuration']['cwd'], root.path);
    expect(parent['configuration']['model'], 'gpt-6.1-sol');
    expect(parent['reasoning'], 'high');
    expect(turnIds(parent), ['one', 'two', 'three']);
    final listed = jsonObject(await client.request('thread/list', {'cwd': other.path}));
    expect((listed['data'] as List).single['name'], 'Child name');
  });

  test('named cutoffs restore the selected context and usage, including through an ancestor', () async {
    for (final boundary in [{'lastTurnId': 'one'}, {'beforeTurnId': 'two'}]) {
      final page = await fork(boundary), child = page['thread']['id'] as String;
      expect(turnIds(page), ['one']);
      expect(page['tokens'], {'input': 100, 'output': 20, 'reasoning': 10, 'cache': {'read': 20, 'write': 0}});
      final nested = await fork({'threadId': child, 'beforeTurnId': 'one'});
      expect(turnIds(nested), isEmpty); expect(nested['tokens'], isNull);
      await turn(child, 'Continue from one');
      final input = jsonEncode(requests.last['input']);
      expect(input, contains('Question one')); expect(input, contains('Answer one'));
      expect(input, isNot(contains('Question two'))); expect(input, isNot(contains('Question three')));
    }
  });

  test('excludeTurns skips usage replay and preserves paginated access after the response', () async {
    final seen = <Json>[];
    final watch = client.events.stream.listen(seen.add);
    try {
      final page = await fork({'excludeTurns': true}), child = page['thread']['id'] as String;
      expect(page['thread']['turns'], isEmpty);
      final turns = jsonObject(await client.request('thread/turns/list', {'threadId': child, 'itemsView': 'full', 'sortDirection': 'asc'}));
      expect((turns['data'] as List).map((turn) => turn['id']), ['one', 'two', 'three']);
      expect(seen.where((event) => event['method'] == 'thread/tokenUsage/updated'), isEmpty);
      expect(seen.where((event) => event['method'] == 'thread/started'), hasLength(1));
    } finally { await watch.cancel(); }
  });

  test('forks of archived sources stay unarchived and retain independent fixed history', () async {
    await client.request('thread/archive', {'threadId': 'parent'});
    final page = await fork(), child = page['thread']['id'] as String;
    expect(page['archived'], false); expect(page['thread']['forkedFromId'], 'parent');
    await client.request('thread/unarchive', {'threadId': 'parent'});
    await turn('parent', 'Later parent question');
    expect(turnIds(await read(child)), ['one', 'two', 'three']);
    await turn(child, 'Private child question');
    expect(jsonEncode((await read('parent'))['thread']), isNot(contains('Private child question')));
  });

  test('ephemeral forks share the prefix, stay pathless and never enter durable listings', () async {
    final page = await fork({'ephemeral': true, 'excludeTurns': true, 'lastTurnId': 'one'});
    final child = page['thread']['id'] as String;
    expect(page['thread']['ephemeral'], true); expect(page['thread']['path'], isNull);
    expect(page['thread']['forkedFromId'], 'parent');
    await turn(child, 'Private ephemeral question');
    expect(turnIds(await read(child)).first, 'one');
    expect(turnIds(await read(child)), hasLength(2));
    expect(await Directory('${root.path}/tasks/$child').exists(), false);
    final listing = jsonObject(await client.request('thread/list'));
    expect((listing['data'] as List).map((thread) => thread['id']), isNot(contains(child)));
    expect(jsonEncode((await read('parent'))['thread']), isNot(contains('Private ephemeral question')));
  });

  test('latest freezes only the child while beforeTurnId can omit a running parent turn', () async {
    final completed = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == 'parent');
    await client.request('turn/start', {'threadId': 'parent', 'input': [{'type': 'text', 'text': 'Hold the parent'}]});
    await held.future.timeout(const Duration(seconds: 10));
    final running = await read('parent'), active = running['thread']['turns'].last['id'];
    await expectLater(fork({'lastTurnId': active}), throwsStateError);
    final before = await fork({'beforeTurnId': active});
    expect(turnIds(before), ['one', 'two', 'three']);
    final latest = await fork(), child = latest['thread']['id'] as String;
    expect(latest['thread']['turns'].last['id'], active);
    expect(latest['thread']['turns'].last['status'], 'interrupted');
    expect((await read('parent'))['running'], true);
    release.complete();
    expect((await completed.timeout(const Duration(seconds: 10)))['params']['turn']['status'], 'completed');
    expect((await read(child))['thread']['turns'].last['status'], 'interrupted');
  });

  test('native Codex usage without a turn id is attributed to the restored visible turn', () async {
    final config = jsonObject((await read('parent'))['configuration']);
    final native = TaskStore(root.path, 'native');
    try {
      native.append('task.created', config, metadata: {'config': config});
      native.append('turn.started', {'turnId': 'native-turn'});
      native.append('input.committed', {'item': ConversationItem.user('Native history').toJson()});
      native.native.append([{'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
        'total_token_usage': {'input_tokens': 240, 'output_tokens': 60, 'total_tokens': 300},
        'last_token_usage': {'input_tokens': 120, 'output_tokens': 30, 'cached_input_tokens': 20,
          'reasoning_output_tokens': 10, 'total_tokens': 150}, 'model_context_window': 200000,
      }}}]);
      native.append('turn.completed', {});
    } finally { native.close(); }
    final restored = client.events.stream.firstWhere((event) => event['method'] == 'thread/tokenUsage/updated');
    final page = await fork({'threadId': 'native'});
    final usage = (await restored.timeout(const Duration(seconds: 10)))['params'];
    expect(usage['threadId'], page['thread']['id']); expect(usage['turnId'], 'native-turn');
    expect(usage['tokenUsage']['input_tokens'], 120); expect(usage['tokenUsage']['reasoning_tokens'], 10);
    expect(page['tokens'], {'input': 100, 'output': 20, 'reasoning': 10, 'cache': {'read': 20, 'write': 0}});
  });

  test('source paths resolve the stored thread and empty paths use threadId', () async {
    final source = await read('parent');
    final byPath = await fork({'threadId': 'ignored', 'path': source['thread']['path'], 'excludeTurns': true});
    expect(byPath['thread']['forkedFromId'], 'parent');
    final byId = await fork({'path': '', 'beforeTurnId': 'two'});
    expect(turnIds(byId), ['one']);
    await expectLater(fork({'path': '${root.path}/missing.sqlite'}), throwsStateError);
  });

  test('invalid boundaries, ephemeral combinations and invalid cwd create no child', () async {
    for (final params in <Json>[
      {'lastTurnId': 'one', 'beforeTurnId': 'two'},
      {'lastTurnId': 'missing'}, {'beforeTurnId': 'missing'},
      {'ephemeral': true}, {'ephemeral': true, 'excludeTurns': true, 'deferGoalContinuation': true},
      {'cwd': '${root.path}/missing'},
    ]) {
      await expectLater(fork(params), throwsStateError);
      final listing = jsonObject(await client.request('thread/list'));
      expect((listing['data'] as List).map((thread) => thread['id']), ['parent']);
    }
  });
}
