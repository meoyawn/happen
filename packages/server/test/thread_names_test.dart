import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

import '../../../test/support/thread.dart';

void main() {
  late Directory root;
  late AgentServer server;
  late AgentClient client, observer;
  late HttpServer provider;
  late Completer<void> arrived, release;
  var hold = false;
  var response = '';
  final requests = <Json>[];
  final sockets = <String, WebSocket>{};
  final socketClosed = <String, Completer<void>>{};
  Future<void> launch() async {
    server = await AgentServer.start(directory: root.path, port: 0, skillsHome: root.path,
      configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
    client = await AgentClient.connect(server.uri);
    observer = await AgentClient.connect(server.uri);
  }
  Future<Json> read() async => jsonObject(await client.request('thread/read', {'threadId': 'saved', 'includeTurns': true}));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('thread-names-');
    requests.clear(); sockets.clear(); socketClosed.clear(); hold = false; response = '{"title":"Fix sidebar thread names"}';
    arrived = Completer<void>(); release = Completer<void>();
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    final config = {'cwd': root.path, 'provider': 'openai', 'model': 'gpt-6.1-sol',
      'provider_settings': {'reasoning': 'medium', 'transport': 'http'}};
    final store = TaskStore(root.path, 'saved');
    try {
      store.append('task.created', config, metadata: {'config': config});
      store.append('turn.started', {'turnId': 'original'});
      store.append('input.committed', {'item': ConversationItem.user('Fix the sidebar thread title').toJson()});
      store.append('model.completed', {'assistantMessageID': 'answer', 'output': [
        ConversationItem(role: 'assistant', content: [{'type': 'reasoning', 'text': 'PRIVATE_REASONING'}],
          native: {'gpt': {'type': 'reasoning', 'id': 'reasoning', 'encrypted_content': 'opaque'}}).toJson(),
        ConversationItem.text('assistant', 'The SidebarName cache never refreshes after a rename.').toJson(),
      ]});
      store.append('turn.completed', {});
    } finally { store.close(); }
    final token = CancellationToken(), catalog = await startServerStore(root.path, cancellation: token);
    try {
      final writer = await startStore(root.path, 'saved', create: false, catalog: catalog.port, cancellation: token);
      await writer.close();
    } finally { await catalog.close(); token.cancel(); }
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Future<Json> reply(Json body) async {
      final naming = body['tool_choice'] == 'none';
      if (naming) {
        requests.add(body);
        if (!arrived.isCompleted) arrived.complete();
        if (hold) await release.future;
      }
      return {'type': 'response.completed', 'response': {'status': 'completed',
        'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': naming ? response : 'A normal answer.'}]}]}};
    }
    provider.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        final id = request.headers.value('session-id')!;
        sockets[id] = socket;
        final closed = socketClosed[id] = Completer<void>();
        socket.listen((raw) async {
          final event = await reply(jsonObject(jsonDecode(raw as String)));
          if (socket.readyState == WebSocket.open) socket.add(jsonEncode(event));
        }, onDone: closed.complete);
      } else {
        final event = await reply(jsonObject(jsonDecode(await utf8.decoder.bind(request).join())));
        request.response.headers.contentType = ContentType('text', 'event-stream');
        request.response.write('data: ${jsonEncode(event)}\n\n');
        try { await request.response.close(); } on IOException { /* Cancelled naming request. */ }
      }
    });
    await launch();
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await observer.close(); await client.close(); await server.close();
    await Future.wait(sockets.values.map((socket) => socket.close()));
    await provider.close(force: true); await root.delete(recursive: true);
  });

  test('saved threads are named on turn admission, never on listing', () async {
    hold = true;
    final saved = await read();
    await client.request('thread/list', {'cwd': root.path});
    await expectLater(arrived.future.timeout(const Duration(seconds: 1)), throwsA(isA<TimeoutException>()));
    expect(requests, isEmpty);
    expect((await read())['thread'], saved['thread']);
    expect(jsonObject(await client.request('thread/loaded/list'))['data'], isEmpty);
    final changed = observer.events.stream.firstWhere((event) => event['method'] == 'thread/name/updated');
    final completed = client.events.stream.firstWhere((event) =>
      event['method'] == 'turn/completed' && event['params']['threadId'] == 'saved');
    await client.request('turn/start', {'threadId': 'saved',
      'input': [{'type': 'text', 'text': 'Make the sidebar refresh the saved thread name'}]});
    await arrived.future.timeout(const Duration(seconds: 10));
    await completed.timeout(const Duration(seconds: 10));
    final before = await read();
    release.complete();
    final notification = await changed.timeout(const Duration(seconds: 10));
    expect(notification['params']['threadId'], 'saved');
    expect(notification['params']['threadName'], 'Fix sidebar thread names');
    final wire = requests.single;
    expect(wire['tools'] as List? ?? const <Object?>[], isEmpty);
    expect(wire['tool_choice'], 'none');
    final input = jsonEncode(wire['input']);
    expect(input, contains('Fix the sidebar thread title'));
    expect(input, isNot(contains('SidebarName')), reason: 'Automatic titles use the first user prompt, not a replay of the conversation.');
    expect(input, isNot(contains('PRIVATE_REASONING')));
    expect(wire['reasoning'], {'effort': 'low', 'context': 'all_turns'});
    expect(wire['max_output_tokens'], 256);
    expect(wire['service_tier'], isNull, reason: 'Title generation uses the standard tier.');
    expect(wire['text']['format']['type'], 'json_schema');
    expect(wire['text']['format']['strict'], isTrue);
    final after = await read();
    expect(after['thread']['turns'], before['thread']['turns']);
    expect(after['thread']['updatedAt'], before['thread']['updatedAt']);
    await observer.close(); await client.close(); await server.close(); await launch();
    final listing = jsonObject(await client.request('thread/list', {'cwd': root.path}));
    expect(listing['data'], hasLength(1));
    expect(listing['data'].single['name'], 'Fix sidebar thread names');
    expect(requests, hasLength(1), reason: 'A saved name takes precedence over another generation.');
  });

  test('turn admission names a thread after its creating client disconnects', () async {
    hold = true;
    final created = jsonObject(await client.request('thread/start', {'cwd': root.path}));
    final id = created['thread']['id'] as String;
    final changed = observer.events.stream.firstWhere((event) =>
      event['method'] == 'thread/name/updated' && event['params']['threadId'] == id);
    final completed = client.events.stream.firstWhere((event) =>
      event['method'] == 'turn/completed' && event['params']['threadId'] == id);
    await client.request('turn/start', {'threadId': id,
      'input': [{'type': 'text', 'text': 'Fix the sidebar thread title'}]});
    await arrived.future.timeout(const Duration(seconds: 10));
    expect((await completed.timeout(const Duration(seconds: 10)))['params']['turn']['status'], 'completed',
      reason: 'The main turn must not wait for its title request.');
    await client.close();
    release.complete();
    expect((await changed.timeout(const Duration(seconds: 10)))['params']['threadName'], 'Fix sidebar thread names');
    final page = jsonObject(await observer.request('thread/read', {'threadId': id, 'includeTurns': true}));
    expect(page['thread']['name'], 'Fix sidebar thread names');
    expect(page['thread']['turns'], hasLength(1), reason: 'Naming must not add a hidden turn to this conversation.');
    expect(jsonEncode(page['thread']['turns']), isNot(contains('"title"')));
    expect(requests, hasLength(1));
  });

  test('title inference bounds the complete UTF-8 prompt and releases its temporary connection', () async {
    final id = await createThread(client, {'cwd': root.path, 'settings': {'transport': 'websocket'}});
    final named = observer.events.stream.firstWhere((event) =>
      event['method'] == 'thread/name/updated' && event['params']['threadId'] == id);
    final prompt = 'Почини соединение ${List.filled(1000, '🚀Ж').join()}';
    expect((await runTurn(client, id, prompt: prompt))['status'], 'completed');
    await named.timeout(const Duration(seconds: 10));
    final wire = requests.single;
    final text = (wire['input'] as List).where((item) => item['type'] == 'message')
      .expand((item) => item['content'] as List).map((part) => part['text'] as String).join();
    expect(utf8.encode(text).length, lessThanOrEqualTo(960));
    expect(text, contains('🚀Ж'));
    expect(text, isNot(contains('\uFFFD')));
    await sockets[wire['prompt_cache_key']]!.done.timeout(const Duration(seconds: 5));
    expect(sockets[id]!.readyState, WebSocket.open, reason: 'The foreground chat keeps its own warm connection.');
  });

  test('manual rename cancels pending title inference before its late response', () async {
    hold = true;
    final id = await createThread(client, {'cwd': root.path, 'settings': {'transport': 'websocket'}});
    expect((await runTurn(client, id, prompt: 'Fix the title lifecycle'))['status'], 'completed');
    await arrived.future.timeout(const Duration(seconds: 10));
    final titleClosed = socketClosed[requests.single['prompt_cache_key']]!.future;
    await client.request('thread/name/set', {'threadId': id, 'name': 'My manual title'});
    await titleClosed.timeout(const Duration(seconds: 5));
    release.complete();
    expect((await runTurn(client, id, prompt: 'Continue'))['status'], 'completed');
    final thread = jsonObject(await client.request('thread/read', {'threadId': id}));
    expect(thread['thread']['name'], 'My manual title');
    expect(requests, hasLength(1));
  });

  test('archive cancels title generation and rejects its late result', () async {
    hold = true;
    final completed = client.events.stream.firstWhere((event) =>
      event['method'] == 'turn/completed' && event['params']['threadId'] == 'saved');
    await client.request('turn/start', {'threadId': 'saved',
      'input': [{'type': 'text', 'text': 'Fix the sidebar thread title'}]});
    await arrived.future.timeout(const Duration(seconds: 10));
    await completed.timeout(const Duration(seconds: 10));
    final renamed = observer.events.stream.firstWhere((event) =>
      event['method'] == 'thread/name/updated' && event['params']['threadId'] == 'saved');
    final lateResult = expectLater(renamed.timeout(const Duration(seconds: 1)), throwsA(isA<TimeoutException>()));
    await client.request('thread/archive', {'threadId': 'saved'});
    expect(await File('${root.path}/tasks/saved/history.sqlite-wal').exists(), false);
    release.complete();
    await lateResult;
    final archived = await read();
    expect(archived['thread']['name'], isNull);
    expect(archived['thread']['status'], {'type': 'notLoaded'});
  });

  test('the persistence owner preserves a manual name over a late automatic result', () async {
    await observer.request('thread/name/set', {'threadId': 'saved', 'name': 'My chosen thread name'});
    final store = TaskStore(root.path, 'saved', create: false);
    try {
      expect(store.setThreadName('A late generated name', onlyIfUnnamed: true), {'name': 'My chosen thread name'});
    } finally { store.close(); }
    expect((await read())['thread']['name'], 'My chosen thread name');
    await client.request('thread/list', {'cwd': root.path});
    expect(requests, isEmpty);
  });
}
