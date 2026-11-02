import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String id;
  late CancellationToken lifetime;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('session-model-');
    id = newId();
    lifetime = CancellationToken();
  });
  tearDown(() async { lifetime.cancel(); await root.delete(recursive: true); });
  Future<Json> read([String method = 'session.message.list', Json params = const {}]) =>
    readSession(root.path, id, method, params, cancellation: lifetime);

  test('system baseline is recorded once and genuine changes still produce updates', () async {
    final store = TaskStore(root.path, id);
    addTearDown(store.close);
    store.append('task.created', {'instructions': 'Baseline'});
    store.append('model.started', {'assistantMessageID': 'msg_1', 'instructions': 'Baseline'});
    store.append('model.started', {'assistantMessageID': 'msg_2', 'instructions': 'Baseline'});
    expect((await read())['data'].where((message) => message['type'] == 'system').map((message) => message['text']), ['Baseline']);
    store.append('model.started', {'assistantMessageID': 'msg_3', 'instructions': 'Changed'});
    store.append('model.started', {'assistantMessageID': 'msg_4', 'instructions': 'Changed'});
    expect((await read())['data'].where((message) => message['type'] == 'system').map((message) => message['text']), ['Baseline', 'Changed']);
  });

  test('incremental base is one classified developer item and notices are not real user input', () async {
    final store = TaskStore(root.path, id);
    addTearDown(store.close);
    store.append('task.created', {'instructions': 'Base prompt'});
    final instructions = ConversationItem(role: 'developer', content: [
      {'type': 'text', 'text': 'Base prompt'},
    ], native: {'harness': {'context': 'model'}});
    store.append('instructions.updated', {'item': instructions.toJson()});
    store.append('model.started', {'assistantMessageID': 'msg_reply', 'instructions': ''});
    store.append('input.committed', {'item': ConversationItem(role: 'user', content: [
      {'type': 'text', 'text': 'Background notification'},
    ], native: {'harness': {'context': 'tool_notification'}}).toJson()});
    final messages = (await read())['data'] as List;
    expect(messages.where((message) => message['type'] == 'system' || message['type'] == 'user'), isEmpty);
    final base = messages.singleWhere((message) => message['context'] == 'model');
    expect(base['type'], 'synthetic');
    expect(base['role'], 'developer');
    expect(store.modelContext().first, instructions.toJson());
    expect((await read('session.inbox'))['data'], isEmpty);
  });

  test('live events and reopened SQLite snapshots produce identical messages and parts', () async {
    final store = TaskStore(root.path, id);
    final live = <String, Json>{}, inbox = <String, dynamic>{};
    void append(String type, Json data, {Json metadata = const {}}) {
      final record = store.append(type, data, metadata: metadata);
      for (final event in record['session_events'] as List) { applySessionEvent(live, jsonObject(event), inbox); }
    }
    const config = {'provider': 'opencode', 'model': 'fixture', 'instructions': 'Baseline prompt',
      'provider_settings': {'context_limit': 10000, 'reasoning': 'high'}};
    append('task.created', config, metadata: {'config': config});
    append('turn.started', {});
    append('input.committed', {'message_id': 'first', 'item': ConversationItem.text('user', 'Read the file').toJson()});
    append('model.started', {'assistantMessageID': 'msg_a', 'instructions': 'Actual system prompt', 'tools': [
      {'namespace': 'functions', 'name': 'read'},
    ]});
    append('model.completed', {'assistantMessageID': 'msg_a', 'output': [
      ConversationItem(role: 'assistant', content: [
        {'type': 'reasoning', 'text': 'Inspect first'},
        {'type': 'tool_call', 'id': 'call_read', 'namespace': 'functions', 'name': 'read', 'input': '{"path":"a.txt"}'},
        {'type': 'text', 'text': 'Reading…'},
      ]).toJson(),
    ], 'usage': {'input_tokens': 100, 'cached_input_tokens': 30, 'cache_write_tokens': 10,
      'output_tokens': 20, 'reasoning_tokens': 5}});
    append('tool.completed', {'item': ConversationItem(role: 'tool', content: [
      {'type': 'tool_result', 'call_id': 'call_read', 'output': 'file content'},
    ]).toJson()});
    append('turn.completed', {});
    final context = store.modelSnapshot();
    store.close();
    final snapshot = await read();
    final saved = {for (final raw in snapshot['data'] as List) raw['id'] as String: jsonObject(raw)};
    expect(saved, live);
    final assistant = saved['msg_a']!;
    expect(assistant['time']['completed'], isA<int>());
    expect(assistant['tokens'], {'input': 60, 'output': 15, 'reasoning': 5, 'cache': {'read': 30, 'write': 10}});
    expect(sessionTokenTotal(jsonObject(assistant['tokens'])), 120);
    expect(assistant['content'][1]['state']['status'], 'completed');
    expect(assistant['content'][2]['text'], 'Reading…');
    expect(context['tokens'], assistant['tokens']);
    expect((context['input'] as List).map((item) => item['role']), ['user', 'assistant', 'tool']);
    expect(Directory('${root.path}/tasks/$id').listSync().where((file) => file.path.endsWith('.sqlite')), hasLength(1));
  });

  test('WAL readers continue during a writer transaction and observe only committed data', () async {
    final store = TaskStore(root.path, id);
    addTearDown(store.close);
    store.append('task.created', {'instructions': 'Before'});
    store.append('model.started', {'assistantMessageID': 'msg_before', 'instructions': 'Before'});
    final before = await read();
    store.db.execute('BEGIN IMMEDIATE');
    try {
      store.db.execute("UPDATE session_message SET data = json_set(data, '\$.text', 'After') WHERE type = 'system'");
      final readers = await Future.wait(List.generate(4, (_) => read()));
      expect(readers.every((page) => jsonEncode(page['data']) == jsonEncode(before['data'])), isTrue);
      store.db.execute('COMMIT');
    } catch (_) { store.db.execute('ROLLBACK'); rethrow; }
    expect((await read())['data'].singleWhere((message) => message['type'] == 'system')['text'], 'After');
  });

  test('durable inbox survives writer teardown and delivery or cancellation removes it exactly once', () async {
    var writer = await startStore(root.path, id);
    await callIsolate(writer.port, 'append', {'type': 'input.pending', 'data': {
      'id': 'queued', 'prompt': 'Later', 'delivery': 'queue', 'reasoning': 'high',
    }});
    await writer.close();
    expect((await read('session.inbox'))['data'].single['prompt'], 'Later');
    writer = await startStore(root.path, id, create: false);
    try {
      final committed = jsonObject(await callIsolate(writer.port, 'append', {'type': 'input.committed', 'data': {
        'message_id': 'queued', 'delivery': 'queue', 'item': ConversationItem.text('user', 'Later').toJson(),
      }}));
      expect((committed['session_events'] as List).map((event) => event['type']), ['session.inbox.delivered']);
      expect((await read('session.inbox'))['data'], isEmpty);
      expect((await read())['data'].single['id'], 'msg_queued');
      await callIsolate(writer.port, 'append', {'type': 'input.pending', 'data': {'id': 'cancelled', 'prompt': 'No', 'delivery': 'queue'}});
      await callIsolate(writer.port, 'session.inbox.cancel', {'reason': 'archived'});
      expect((await read('session.inbox'))['data'], isEmpty);
      expect(await callIsolate(writer.port, 'session.inbox.cancel', {'reason': 'archived'}), isNull);
    } finally { await writer.close(); }
  });

  test('existing histories rebuild in the writer and opaque pagination tolerates new messages', () async {
    final store = TaskStore(root.path, id);
    addTearDown(store.close);
    for (var i = 0; i < 5; i++) {
      store.append('input.committed', {'message_id': '$i', 'item': ConversationItem.text('user', '$i').toJson()});
    }
    final expected = (await read())['data'];
    store.db.execute('DELETE FROM session_part; DELETE FROM session_message; DELETE FROM session_event; DELETE FROM session_inbox;');
    store.db.execute("UPDATE session_projection SET through_seq = 0, data = '{}'");
    expect((await read())['needsProjection'], true);
    await store.prepareSession(cancellation: lifetime);
    expect((await read())['data'], expected);
    var page = await read('session.message.list', {'limit': 2});
    final ids = <String>[for (final message in page['data']) message['id'] as String];
    store.append('input.committed', {'message_id': 'new', 'item': ConversationItem.text('user', 'New').toJson()});
    while (page['cursor']['next'] != null) {
      page = await read('session.message.list', {'limit': 2, 'cursor': page['cursor']['next']});
      ids.insertAll(0, [for (final message in page['data']) message['id'] as String]);
    }
    expect(ids, ['msg_0', 'msg_1', 'msg_2', 'msg_3', 'msg_4']);
    store.append('compaction.started', {'reason': 'manual'});
    store.append('context.compacted', {'reason': 'manual', 'summary': 'Checkpoint', 'input': []});
    final context = store.modelSnapshot();
    expect(context['tokens'], isNull);
    expect(context['input'], isEmpty);
  });
}
