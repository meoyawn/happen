// Behavioral ports of Codex 5112ce6edeb9 tui/src/app/{side.rs,tests.rs},
// app_server_session::fork_side_thread, and chatwidget/tests/side.rs.
// The real transport, inference actor and SQLite owner are exercised together.
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
  late AgentClient client;
  late HttpServer provider;
  late StreamController<Json> arrived;
  late Completer<void> release;
  final requests = <Json>[];
  Future<void> turn(String id, String prompt, {String? effort}) async {
    final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == id);
    await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': prompt}], if (effort != null) 'effort': effort});
    expect((await done.timeout(const Duration(seconds: 10)))['params']['turn']['status'], 'completed');
  }
  Future<String> start({bool send = true}) async {
    final page = jsonObject(await client.request('thread/start', {'cwd': root.path, 'developerInstructions': 'Existing developer policy.'}));
    final id = page['thread']['id'] as String;
    if (send) await turn(id, 'Parent question');
    return id;
  }
  Future<Json> context(String id) async => jsonObject(await client.request('session.context', {'sessionID': id}));
  Future<Json> read(String id) async => jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
  Future<Json> side(String id, {String prompt = ''}) => client.createSideChat(id, prompt: prompt, cancellation: CancellationToken());
  Future<void> close(String id) async { await client.request('session.side.close', {'sessionID': id}); }
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-side-'); requests.clear();
    release = Completer<void>(); arrived = StreamController<Json>.broadcast();
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requests.add(body); arrived.add(body);
      if (jsonEncode((body['input'] as List).last).contains('hold ')) await release.future;
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed',
        'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'A separate answer.'}]}]}})}\n\n');
      try { await request.response.close(); } on IOException { /* Interrupted side response. */ }
    });
    server = await AgentServer.start(directory: root.path, port: 0, skillsHome: root.path,
      endpoint: 'http://127.0.0.1:${provider.port}/responses');
    client = await AgentClient.connect(server.uri);
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await client.close(); await server.close(); await provider.close(force: true);
    await arrived.close(); await root.delete(recursive: true);
  });

  test('side_start_error_message_explains_missing_first_prompt', () async {
    final id = await start(send: false);
    await expectLater(side(id), throwsA(isA<StateError>().having((error) => error.message, 'message',
      contains("'/side' is unavailable until the current conversation has started. Send a message first, then try /side again."))));
    expect(requests, isEmpty);
    expect(jsonObject(await client.request('session.side.list', {'sessionID': id}))['data'], isEmpty);
  });

  test('side boundary, developer guardrails and ephemeral runtime settings reach the model, not the transcript', () async {
    final id = await start();
    await turn(id, 'Use the current reasoning effort', effort: 'high');
    final before = await context(id), fork = await side(id), child = fork['sessionID'] as String;
    final config = jsonObject(fork['configuration']);
    expect(config['ephemeral'], true); expect(config['daybreak_enabled'], false);
    expect(config['model'], (await read(id))['configuration']['model']);
    expect(config['provider_settings']['reasoning'], 'high');
    final saved = await context(child), input = (saved['input'] as List).map((item) => ConversationItem.fromJson(jsonObject(item))).toList();
    final boundary = input.last;
    expect(boundary.role, 'user');
    for (final text in ['Side conversation boundary.', 'Everything before this boundary is inherited history',
      'It is not your current task.', 'Only messages submitted after this boundary are active',
      'Do not continue, execute, or complete', 'separate from the main thread',
      "External tools may be available according to this thread's current", 'Sub-agents are off-limits in this side conversation.',
      'Do not call create_worktree here.', 'Do not modify files', 'Do not request escalated permissions']) {
      expect(boundary.text, contains(text));
    }
    final developer = input.where((item) => item.role == 'developer' && item.text.contains('You are in a side conversation, not the main thread.')).single;
    expect(developer.text, contains('Existing developer policy.'));
    expect(developer.text, contains('non-mutating inspection'));
    expect(developer.text, contains('Do not continue, execute, or complete any task'));
    final visible = await read(child);
    expect(visible['thread']['ephemeral'], true); expect(visible['thread']['path'], isNull);
    expect(visible['thread']['forkedFromId'], isNull); expect(visible['thread']['turns'], isEmpty);
    expect(jsonObject(await client.request('thread/items/list', {'threadId': child}))['data'], isEmpty);
    expect(requests, hasLength(2), reason: 'A bare /side waits for a question.');
    expect(await Directory('${root.path}/tasks/$child').exists(), false);
    await turn(child, '!echo hello');
    final wire = jsonEncode(requests.last['input']);
    expect(wire, contains('You are in a side conversation, not the main thread.'));
    expect(wire, contains('!echo hello'));
    expect((await context(id))['input'], before['input']);
    expect((await read(child))['thread']['turns'], hasLength(1));
  });

  test('handle_start_side reuses a parent side and submits the next question there without touching the parent', () async {
    final id = await start(), forks = await Future.wait([side(id), side(id)]), child = forks.first['sessionID'] as String;
    expect(forks.last['sessionID'], child, reason: 'Overlapping requests must share the same ephemeral fork.');
    final before = await context(id);
    final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == child);
    expect((await side(id, prompt: 'Follow-up question'))['sessionID'], child);
    await done.timeout(const Duration(seconds: 10));
    expect(jsonObject(await client.request('session.side.list', {'sessionID': id}))['data'], hasLength(1));
    expect((await context(id))['input'], before['input']);
    await turn(id, 'New parent history after fork');
    expect(jsonEncode((await context(child))['input']), isNot(contains('New parent history after fork')));
    await close(child);
    expect(jsonObject(await client.request('session.side.list', {'sessionID': id}))['data'], isEmpty);
    expect((await side(id))['sessionID'], isNot(child));
  });

  test('inherited unfinished tools are reference-only and never executed or cancelled in the parent', () async {
    final parent = await start();
    final config = jsonObject((await read(parent))['configuration']);
    final store = TaskStore(root.path, 'unfinished-parent');
    try {
      store.append('task.created', config, metadata: {'config': config});
      store.append('turn.started', {'id': 'inherited-turn'});
      store.append('input.committed', {'item': ConversationItem.user('Inherited task').toJson()});
      store.append('model.completed', {'assistantMessageID': 'inherited-assistant', 'output': [ConversationItem(role: 'assistant', content: [
        {'type': 'tool_call', 'id': 'never-run', 'name': 'exec', 'input': 'throw new Error("inherited")'},
      ]).toJson()]});
    } finally { store.close(); }
    final before = await context('unfinished-parent'), fork = await side('unfinished-parent');
    final child = fork['sessionID'] as String;
    final input = ((await context(child))['input'] as List).map((item) => ConversationItem.fromJson(jsonObject(item))).toList();
    expect(input.expand((item) => item.content).where((part) => part['type'] == 'tool_result' && part['call_id'] == 'never-run'), hasLength(1));
    expect((await context('unfinished-parent'))['input'], before['input']);
    expect((await read(child))['thread']['turns'], isEmpty);
    expect(requests, hasLength(1));
  });

  test('side conversations reject durable lifecycle operations and goals with the owning guard', () async {
    final id = (await side(await start()))['sessionID'] as String;
    for (final method in ['thread/fork', 'thread/archive', 'thread/unarchive', 'thread/name/set',
      'thread/goal/get', 'thread/goal/set', 'thread/goal/clear']) {
      await expectLater(client.request(method, {'threadId': id, 'name': 'renamed', 'objective': 'goal'}),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
          contains(method == 'thread/name/set' ? 'cannot be renamed' : method.startsWith('thread/goal/') ? 'ephemeral thread' : 'ephemeral'))));
    }
    await expectLater(side(id), throwsA(isA<StateError>().having((error) => error.message, 'message', contains('main'))));
    expect((await read(id))['thread']['turns'], isEmpty);
  });

  test('discard interrupts only the side, removes its navigation and ignores late events', () async {
    final id = await start(), parentArrived = arrived.stream.first;
    await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'hold parent'}]});
    await parentArrived.timeout(const Duration(seconds: 10));
    final sideArrived = arrived.stream.first, fork = await side(id, prompt: 'hold side'), child = fork['sessionID'] as String;
    await sideArrived.timeout(const Duration(seconds: 10));
    await close(child).timeout(const Duration(seconds: 10));
    expect((await read(id))['running'], true);
    expect(jsonObject(await client.request('session.side.list', {'sessionID': id}))['data'], isEmpty);
    expect(jsonObject(await client.request('thread/loaded/list', {}))['data'], isNot(contains(child)));
    await expectLater(read(child), throwsStateError);
    final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == id);
    release.complete(); await done.timeout(const Duration(seconds: 10));
    expect(jsonEncode((await context(id))['input']), isNot(contains('hold side')));
    expect(await Directory('${root.path}/tasks/$child').exists(), false);
  });

  test('cancelling side admission disposes the new in-memory owner without affecting the parent', () async {
    final id = await start(), token = CancellationToken();
    final closed = client.events.stream.firstWhere((event) => event['method'] == 'happen/side/closed');
    String? child;
    final watch = client.events.stream.listen((event) {
      if (event['method'] == 'happen/inbox/enqueued' && event['params']['threadId'] != id) {
        child = event['params']['threadId'] as String; token.cancel();
      }
    });
    try {
      await expectLater(client.createSideChat(id, prompt: 'hold cancelled side', cancellation: token), throwsA(isA<CancelledException>()));
      expect((await closed.timeout(const Duration(seconds: 10)))['params']['threadId'], child);
      expect(child, isNotNull);
      expect(jsonObject(await client.request('session.side.list', {'sessionID': id}))['data'], isEmpty);
      expect((await read(id))['thread']['turns'], hasLength(1));
      expect(await Directory('${root.path}/tasks/$child').exists(), false);
    } finally { token.cancel(); await watch.cancel(); }
  });
}
