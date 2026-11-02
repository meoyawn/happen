import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('failed history replay does not block archiving, inbox cancellation, or restoring', () async {
    final root = await Directory.systemTemp.createTemp('session-archive-');
    addTearDown(() => root.delete(recursive: true));
    final id = newId();
    final store = TaskStore(root.path, id);
    try {
      store.append('input.pending', {'id': 'delivered', 'prompt': 'Before', 'delivery': 'queue'});
      store.append('input.pending', {'id': 'before', 'prompt': 'Keep queued', 'delivery': 'queue'});
      // A saved execution fact that cannot be projected into a conversation.
      store.db.execute('INSERT INTO events(id, window_id, type, created_at, data) VALUES (?, ?, ?, ?, ?)',
        [newId(), '$id:0', 'model.started', DateTime.now().toUtc().toIso8601String(), '{}']);
      store.append('input.committed', {'message_id': 'delivered', 'item': ConversationItem.text('user', 'Before').toJson()});
      store.append('input.pending', {'id': 'cancelled', 'prompt': 'Already cancelled', 'delivery': 'queue'});
      store.append('input.discarded', {'ids': ['cancelled'], 'reason': 'cancelled'});
      store.append('input.pending', {'id': 'after', 'prompt': 'Later', 'delivery': 'queue'});
    } finally { store.close(); }

    final server = await AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml', port: 0);
    addTearDown(server.close);
    final client = await AgentClient.connect(server.uri);
    addTearDown(client.close);
    await expectLater(client.request('session.message.list', {'sessionID': id}),
      throwsA(isA<StateError>().having((error) => error.toString(), 'error', contains('assistantMessageID'))));
    final before = await client.request('history.page', {'task_id': id}) as List;
    final events = <Json>[];
    final subscription = client.events.stream.listen(events.add);
    addTearDown(subscription.cancel);
    await expectLater(client.request('session.archive', {'sessionID': id}), completes,
      reason: 'Archiving must not require successful history replay');
    expect(events.singleWhere((event) => event['type'] == 'session.archived')['data']['sessionID'], id);
    final history = await client.request('history.page', {'task_id': id}) as List;
    expect(history.take(before.length), before, reason: 'Archiving preserves every saved execution fact');
    expect(history[before.length]['type'], 'input.discarded');
    expect(history[before.length]['data']['ids'], ['before', 'after']);
    expect(history.last['type'], 'task.archived');

    final saved = TaskStore(root.path, id, create: false);
    try { expect(saved.metadata('archived_at'), isA<String>()); }
    finally { saved.close(); }
    await client.request('session.unarchive', {'sessionID': id});
    final restored = TaskStore(root.path, id, create: false);
    try {
      expect(restored.metadata('archived_at'), isNull);
      final events = restored.history();
      expect(events.last['type'], 'task.unarchived');
      expect(events.where((event) => event['type'] == 'input.discarded').last['data']['ids'], ['before', 'after']);
    } finally { restored.close(); }
  });
}
