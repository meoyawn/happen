import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('the server discovers interrupted histories without a desktop reference or restarting execution', () async {
    final root = await Directory.systemTemp.createTemp('session-registry-');
    addTearDown(() => root.delete(recursive: true));
    final work = await Directory('${root.path}/work').create();
    final id = newId();
    final store = TaskStore(root.path, id);
    final config = {'cwd': work.path, 'provider': 'openai', 'model': 'gpt-6.1-sol',
      'tool_interface': 'openai', 'instructions': '', 'provider_settings': {'reasoning': 'high'}};
    store.append('task.created', config, metadata: {'config': config});
    store.append('input.committed', {'message_id': newId(),
      'item': ConversationItem.text('user', 'Recover the saved session\nWithout replaying its tools').toJson()});
    store.append('turn.started', {'id': newId()}, metadata: {'status': 'running'});
    store.append('host_tool.started', {'id': 'unfinished', 'name': 'exec_command',
      'arguments': {'cmd': 'a command that must not be replayed'}});
    final through = store.lastSequence;
    store.close();

    for (var launch = 0; launch < 2; launch++) {
      final server = await AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml', port: 0);
      final client = await AgentClient.connect(server.uri);
      try {
        final page = jsonObject(await client.request('session.list', {'directory': work.path, 'limit': 1}));
        final info = jsonObject((page['data'] as List).single);
        expect(info['id'], id);
        expect(info['title'], 'Recover the saved session');
        expect(info['location']['directory'], work.path);
        expect(info['time']['busy'], isA<int>());
        expect(info['time'].containsKey('idle'), false);
        final listed = jsonObject(await client.request('session.list', {'directory': work.path}));
        expect(listed['data'], hasLength(1), reason: 'Repeated discovery never duplicates a session');
        expect(jsonObject(await client.request('session.active'))['data'], isEmpty);
        final stats = jsonObject(await client.request('telemetry'));
        expect(stats['active_tasks'], 0);
        expect(stats['counters']['model_requests'], isNull);
        final history = await client.request('history.page', {'task_id': id}) as List;
        expect(history, hasLength(through));
        expect(history.last['type'], 'host_tool.started');
      } finally {
        await client.close();
        await server.close();
      }
    }
  });

  test('session pages retain their filters and order across ties, archives and broken neighbours', () async {
    final root = await Directory.systemTemp.createTemp('session-list-');
    addTearDown(() => root.delete(recursive: true));
    final work = await Directory('${root.path}/work').create();
    final other = await Directory('${root.path}/other').create();
    final ids = <String>[];
    for (var index = 0; index < 5; index++) {
      final id = newId();
      ids.add(id);
      final store = TaskStore(root.path, id);
      final config = {'cwd': index == 2 ? other.path : work.path, 'provider': 'openai', 'model': 'fixture'};
      store.append('task.created', config, metadata: {'config': config, 'title': 'Saved session $index'});
      if (index == 3) store.archive(true);
      if (index == 4) store.append('task.forked', {'parent_id': ids.first});
      store.db.execute("UPDATE events SET created_at = '2026-01-01T00:00:00.000Z'");
      store.close();
    }
    final broken = await Directory('${root.path}/tasks/${newId()}').create();
    await File('${broken.path}/history.sqlite').writeAsString('Not a SQLite database');
    final server = await AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml', port: 0);
    final client = await AgentClient.connect(server.uri);
    try {
      final first = jsonObject(await client.request('session.list', {
        'directory': '${work.path}/', 'archived': false, 'parentID': null, 'limit': 1,
      }));
      final second = jsonObject(await client.request('session.list', {
        'cursor': first['cursor']['next'], 'directory': other.path, 'limit': 1,
      }));
      final expected = ids.take(2).toList()..sort((a, b) => b.compareTo(a));
      expect([first['data'].single['id'], second['data'].single['id']], expected);
      final back = jsonObject(await client.request('session.list', {'cursor': second['cursor']['previous'], 'limit': 1}));
      expect(back['data'], first['data']);
      final end = jsonObject(await client.request('session.list', {'cursor': second['cursor']['next'], 'limit': 1}));
      expect(end['data'], isEmpty);
      final archived = jsonObject(await client.request('session.list', {'archived': true}));
      expect(archived['data'].single['id'], ids[3]);
      final children = jsonObject(await client.request('session.list', {'parentID': ids.first}));
      expect(children['data'].single['id'], ids[4]);
      final search = jsonObject(await client.request('session.list', {'search': 'SESSION 2'}));
      expect(search['data'].single['id'], ids[2]);
      await expectLater(client.request('session.list', {'cursor': 'not-a-cursor'}), throwsStateError);
    } finally {
      await client.close();
      await server.close();
    }
  });
}
