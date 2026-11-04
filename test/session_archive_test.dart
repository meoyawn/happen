import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('archive cancels pending input even when the rebuildable history projection fails', () async {
    final root = await Directory.systemTemp.createTemp('thread-archive-');
    addTearDown(() => root.delete(recursive: true));
    final id = newId(), store = TaskStore(root.path, newId());
    // Use the server's session ID below, not a parallel writer.
    final actualID = store.taskId;
    store.append('task.created', {'cwd': root.path}, metadata: {'config': {'cwd': root.path}});
    store.db.execute("CREATE TRIGGER broken BEFORE INSERT ON thread_turns BEGIN SELECT RAISE(ABORT,'broken projection'); END");
    store.append('turn.started', {'turnId': id});
    store.append('input.pending', {'id': 'queued', 'prompt': 'Never execute', 'delivery': 'queue'});
    final canonical = store.db.select('SELECT line FROM rollout_lines').map((row) => row['line']).toList();
    store.close();
    final server = await AgentServer.start(directory: root.path, port: 0, configPath: '${root.path}/config.yaml');
    final client = await AgentClient.connect(server.uri);
    try {
      await client.request('thread/archive', {'threadId': actualID});
      final saved = TaskStore(root.path, actualID, create: false);
      try {
        expect(saved.metadata('archived_at'), isA<String>());
        expect(saved.inbox()['data'], isEmpty);
        expect(saved.db.select('SELECT line FROM rollout_lines').map((row) => row['line']), canonical);
        saved.db.execute('DROP TRIGGER broken');
      } finally { saved.close(); }
      await client.request('thread/unarchive', {'threadId': actualID});
      final restored = TaskStore(root.path, actualID, create: false);
      try { expect(restored.metadata('archived_at'), isNull); expect(restored.inbox()['data'], isEmpty); }
      finally { restored.close(); }
    } finally { await client.close(); await server.close(); }
  });
}
