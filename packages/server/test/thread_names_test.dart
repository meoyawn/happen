import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late AgentServer server;
  late AgentClient client, observer;
  late HttpServer provider;
  late Completer<void> arrived, release;
  var hold = false;
  var response = '';
  final requests = <Json>[];
  Future<void> launch() async {
    server = await AgentServer.start(directory: root.path, port: 0, skillsHome: root.path,
      configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
    client = await AgentClient.connect(server.uri);
    observer = await AgentClient.connect(server.uri);
  }
  Future<Json> read() async => jsonObject(await client.request('thread/read', {'threadId': 'saved', 'includeTurns': true}));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('thread-names-');
    requests.clear(); hold = false; response = '{"title":"Fix sidebar thread names"}';
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
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      final naming = body['tool_choice'] == 'none';
      if (naming) {
        requests.add(body);
        if (!arrived.isCompleted) arrived.complete();
        if (hold) await release.future;
      }
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed',
        'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': naming ? response : 'A normal answer.'}]}]}})}\n\n');
      try { await request.response.close(); } on IOException { /* Cancelled naming request. */ }
    });
    await launch();
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await observer.close(); await client.close(); await server.close();
    await provider.close(force: true); await root.delete(recursive: true);
  });

  test('context names persist, reach unsubscribed sidebars and leave the conversation intact', () async {
    final before = await read();
    final changed = observer.events.stream.firstWhere((event) => event['method'] == 'thread/name/updated');
    await client.request('thread/list', {'cwd': root.path});
    final notification = await changed.timeout(const Duration(seconds: 10));
    expect(notification['params']['threadId'], 'saved');
    expect(notification['params']['threadName'], 'Fix sidebar thread names');
    final wire = requests.single;
    expect(wire['tools'] as List? ?? const <Object?>[], isEmpty);
    expect(wire['tool_choice'], 'none');
    final input = jsonEncode(wire['input']);
    expect(input, contains('Fix the sidebar thread title'));
    expect(input, contains('SidebarName'));
    expect(input, isNot(contains('PRIVATE_REASONING')));
    final after = await read();
    expect(after['thread']['turns'], before['thread']['turns']);
    expect(after['thread']['updatedAt'], before['thread']['updatedAt']);
    expect(jsonObject(await client.request('thread/loaded/list'))['data'], isEmpty);
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
