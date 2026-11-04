// CLI storage contracts copied from happen-storage-codex, with the same exact
// provider-neutral context retained beside native Codex RolloutLines.
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late TaskStore store;
  setUp(() { root = Directory.systemTemp.createTempSync('native-integration-'); store = TaskStore(root.path, 'session'); });
  tearDown(() { store.close(); root.deleteSync(recursive: true); });
  const config = {'provider': 'openai', 'model': 'gpt-6.1-terra', 'cwd': '/tmp', 'provider_settings': {'reasoning': 'max'}};
  void seed() => store.append('task.created', config, metadata: {'config': config});
  final user = ConversationItem.user('Open and close https://example.com/').toJson();
  final answer = ConversationItem(role: 'assistant', content: [
    {'type': 'reasoning', 'text': 'Planning', 'native': {'gpt': {'type': 'summary_text'}}},
    {'type': 'text', 'text': 'Opening.'},
    {'type': 'tool_call', 'id': 'call-1', 'name': 'exec', 'namespace': 'functions', 'input': 'text("hello")', 'format': 'text',
      'native': {'gpt': {'id': 'ctc_test', 'type': 'custom_tool_call', 'status': 'completed'}}},
  ], native: {'gpt': {'type': 'reasoning', 'id': 'rs_test', 'encrypted_content': 'opaque_checkpoint'}}).toJson();
  final result = ConversationItem(role: 'tool', content: [
    {'type': 'tool_result', 'call_id': 'call-1', 'name': 'exec', 'namespace': 'functions', 'output': 'page 2 closed', 'is_error': false},
  ]).toJson();
  test('exact model input, configuration, KV, and native provider fields survive reopen', () {
    seed(); store.append('input.committed', {'item': user});
    store.append('model.started', {'assistantMessageID': 'assistant-1'});
    store.appendBatch([
      {'type': 'model.completed', 'data': {'assistantMessageID': 'assistant-1', 'output': [answer], 'usage': {'input_tokens': 4, 'output_tokens': 3}}},
      {'type': 'tool.started', 'data': {'call_id': 'call-1', 'name': 'exec', 'input': 'source code'}},
    ]);
    store.append('tool.completed', {'item': result});
    store.keyValue('set', {'key': 'persisted', 'value': {'id': 2}});
    final before = store.modelSnapshot();
    store.close(); store = TaskStore(root.path, 'session', create: false);
    expect(store.modelContext(), [user, answer, result]); expect(store.modelSnapshot(), before);
    expect(store.metadata('config'), config); expect(store.keyValue('get', {'key': 'persisted'}), {'id': 2});
    expect(store.db.select("SELECT name FROM sqlite_master WHERE name IN ('events','conversation_events','conversation_parts','session_projection')"), isEmpty);
  });
  test('invalid caller batch leaves neither context nor a new sequence', () {
    seed(); final before = store.modelSnapshot();
    expect(() => store.appendBatch([{'type': 'input.committed', 'data': {'item': user}}, {'data': <String, Object?>{}}]), throwsA(anything));
    expect(store.modelSnapshot(), before);
    store.close(); store = TaskStore(root.path, 'session', create: false); expect(store.modelSnapshot(), before);
  });
  test('compaction replaces the model window but keeps earlier native history', () {
    seed(); store.append('input.committed', {'item': user});
    final summary = ConversationItem.user('Summary of previous actions.').toJson();
    store.append('context.compacted', {'input': [summary], 'summary': 'Summary of previous actions.'});
    final nextUser = ConversationItem.user('Open and close https://example.com/').toJson();
    store.append('input.committed', {'item': nextUser});
    store.close(); store = TaskStore(root.path, 'session', create: false);
    expect(store.modelContext(), [summary, nextUser]);
    expect(store.db.select("SELECT item_id FROM thread_items WHERE item_type IS 'userMessage'"), hasLength(2));
  });
  test('inbox admission survives teardown; withdrawn and queued offers cannot commit', () async {
    seed();
    for (final id in ['queue', 'deleted', 'deliver']) {
      store.append('input.pending', {'id': id, 'prompt': id, 'delivery': 'steer', 'reasoning': 'high',
        'attachments': [{'type': 'file', 'name': '$id.txt', 'path': '/$id.txt'}]});
    }
    store.changeSessionInbox('msg_queue', delivery: 'queue'); store.changeSessionInbox('msg_deleted');
    store.close(); store = TaskStore(root.path, 'session', create: false);
    final records = store.commitSessionSteering(['queue', 'deleted', 'deliver', 'deliver'], effort: 'low', reasoningUpdates: true);
    expect(records.where((record) => record['type'] == 'input.committed').map((record) => record['data']['message_id']), ['deliver']);
    expect(store.inbox()['data'].single['id'], 'queue');
    expect(store.metadata('effective_reasoning'), 'high');
    expect(store.modelContext().last['content'].last['path'], '/deliver.txt');
    expect(() => store.changeSessionInbox('msg_deliver'), throwsStateError);
  });
  test('read-only WAL snapshots run concurrently without observing an uncommitted writer', () async {
    seed(); store.append('turn.started', {'turnId': 'one'});
    store.append('input.committed', {'item': user}); store.append('turn.completed', {});
    final cancellation = CancellationToken();
    final before = await readSession(root.path, 'session', 'thread/read', {'includeTurns': true}, cancellation: cancellation);
    store.db.execute('BEGIN IMMEDIATE');
    try {
      store.db.execute("UPDATE thread_items SET item_json=json_set(item_json,'\$.content[0].text','Uncommitted')");
      final readers = await Future.wait(List.generate(4, (_) => readSession(root.path, 'session', 'thread/read', {'includeTurns': true}, cancellation: cancellation)));
      expect(readers, everyElement(before));
    } finally { store.db.execute('ROLLBACK'); cancellation.cancel(); }
  });
}
