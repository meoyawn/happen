import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('native thread listing discovers durable interrupted sessions without running their tools', () async {
    final root = await Directory.systemTemp.createTemp('native-inventory-');
    addTearDown(() => root.delete(recursive: true));
    final store = TaskStore(root.path, 'saved');
    final config = {'cwd': root.path, 'provider': 'openai', 'model': 'fixture'};
    store.append('task.created', config, metadata: {'config': config});
    store.append('turn.started', {'turnId': 'interrupted'});
    store.append('input.committed', {'item': ConversationItem.user('Recover the saved session').toJson()});
    store.append('host_tool.started', {'id': 'unfinished', 'name': 'exec_command', 'arguments': {'cmd': 'must not execute'}});
    store.close();
    for (var launch = 0; launch < 2; launch++) {
      final server = await AgentServer.start(directory: root.path, port: 0, configPath: '${root.path}/config.yaml');
      final client = await AgentClient.connect(server.uri);
      try {
        final page = jsonObject(await client.request('thread/list', {'cwd': root.path, 'limit': 1})), info = jsonObject(page['data'].single);
        expect(info['id'], 'saved'); expect(info['preview'], 'Recover the saved session'); expect(info['cwd'], root.path);
        expect(info['historyMode'], 'paginated'); expect(info['turns'], isEmpty); expect(info['status'], {'type': 'notLoaded'});
        expect((await client.request('thread/loaded/list') as Map)['data'], isEmpty); expect(server.activeTaskCount, 0);
      } finally { await client.close(); await server.close(); }
    }
  });

  test('opaque list cursors retain native filters and order despite archives and broken neighbours', () async {
    final root = await Directory.systemTemp.createTemp('native-pages-');
    addTearDown(() => root.delete(recursive: true));
    for (final id in ['a', 'b', 'c']) {
      final store = TaskStore(root.path, id), config = {'cwd': root.path, 'provider': 'openai', 'model': 'fixture'};
      store.append('task.created', config, metadata: {'config': config});
      if (id == 'c') store.archive(true);
      store.db.execute("UPDATE happen_runtime SET data=json_set(data,'\$.updated',1767225600000)"); store.close();
    }
    final broken = await Directory('${root.path}/tasks/broken').create(); await File('${broken.path}/history.sqlite').writeAsString('Not SQLite');
    final token = CancellationToken();
    try {
      final first = await listThreads(root.path, {'cwd': root.path, 'limit': 1}, cancellation: token);
      final second = await listThreads(root.path, {'cursor': first['nextCursor'], 'cwd': '/ignored', 'limit': 1}, cancellation: token);
      expect([first['data'].single['id'], second['data'].single['id']], ['b', 'a']); expect(second['nextCursor'], isNull);
      expect((await listThreads(root.path, {'archived': true}, cancellation: token))['data'].single['id'], 'c');
      await expectLater(listThreads(root.path, {'cursor': 'bad'}, cancellation: token), throwsA(isA<FormatException>()));
    } finally { token.cancel(); }
  });
}
