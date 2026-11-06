import 'dart:io';

import 'package:ai/ai.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';

void main() {
  test('history summaries, older pages and live completions preserve source order', () async {
    final root = await Directory.systemTemp.createTemp('conversation-order-');
    AgentServer? server;
    DesktopSession? session;
    addTearDown(() async {
      await session?.close();
      await server?.close();
      await root.delete(recursive: true);
    });
    final config = {'cwd': root.path, 'provider': 'openai', 'model': 'gpt-6.1-sol'};
    final expected = <String>[];
    final store = TaskStore(root.path, 'ordering');
    try {
      store.append('task.created', config, metadata: {'config': config});
      for (final turn in ['one', 'two']) {
        store.append('turn.started', {'turnId': turn});
        final user = ConversationItem.user('Question $turn').toJson();
        expected.add(user['id'] as String);
        store.append('input.committed', {'item': user});
        for (var i = 0; i < 53; i++) {
          final id = '$turn:thought:$i';
          expected.add(id);
          store.append('native.item.completed', {'turnId': turn, 'completedAtMs': 1000,
            'item': {'id': id, 'type': 'reasoning', 'summary': ['Thought $i'], 'content': <String>[]}});
        }
        if (turn == 'two') {
          expected.add('compaction');
          store.append('native.item.completed', {'turnId': turn, 'completedAtMs': 1,
            'item': {'id': 'compaction', 'type': 'contextCompaction'}});
        }
        final id = '$turn:answer';
        expected.add(id);
        store.append('native.item.completed', {'turnId': turn, 'completedAtMs': 500,
          'item': {'id': id, 'type': 'agentMessage', 'text': 'Answer $turn', 'phase': 'final_answer'}});
        store.append('turn.completed', {});
      }
    } finally { store.close(); }
    server = await AgentServer.start(directory: root.path, port: 0,
      configPath: '${root.path}/config.yaml', skillsHome: root.path);
    final desktop = session = DesktopSession(await AgentClient.connect(server.uri), await openDesktopDatabase(root.path));
    final task = DesktopTask('ordering', 'Conversation');
    await desktop.loadHistory(task);
    expect(task.loadError, isNull);
    expect(task.historyBefore, isNotNull);
    expect(conversation(task).map((entry) => entry.id), expected.where(task.messages.containsKey));
    await desktop.loadEarlier(task);
    expect(task.loadError, isNull);
    expect(conversation(task).map((entry) => entry.id), expected);
    for (final event in [
      {'method': 'item/started', 'params': {'turnId': 'three',
        'item': {'id': 'live', 'type': 'agentMessage', 'text': 'Starting', 'startedAtMs': 0}}},
      {'method': 'item/completed', 'params': {'turnId': 'three',
        'item': {'id': 'live', 'type': 'agentMessage', 'text': 'Finished', 'completedAtMs': 0}}},
    ]) {
      applyThreadNotification(task.messages, event);
      expect(conversation(task).map((entry) => entry.id), [...expected, 'live']);
    }
    task.liveText.dispose();
  });
}
