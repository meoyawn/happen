import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  for (final method in ['read', 'list']) {
    for (final cancel in [false, true]) {
      test('concurrent $method waits for a real SQLite read lock${cancel ? ' and remains caller-cancellable' : ' instead of hiding the saved session'}', () async {
        final root = await Directory.systemTemp.createTemp('locked-read-'), token = CancellationToken(), port = ReceivePort();
        final store = TaskStore(root.path, 'saved'), config = {'cwd': root.path, 'provider': 'openai', 'model': 'fixture'};
        store.append('task.created', config, metadata: {'config': config}); store.close();
        final blocker = sqlite3.open('${root.path}/tasks/saved/history.sqlite');
        var closed = false;
        final busy = Completer<void>(), events = port.listen((raw) {
          if (jsonObject(raw)['event']?['name'] == 'sqlite.read.busy' && !busy.isCompleted) busy.complete();
        });
        try {
          blocker.execute('PRAGMA locking_mode=EXCLUSIVE'); blocker.execute('BEGIN EXCLUSIVE'); blocker.select('SELECT data FROM happen_runtime');
          final reading = withTrace(TraceContext(sink: port.sendPort, service: 'storage'), () => method == 'read'
            ? readSession(root.path, 'saved', 'thread/read', {}, cancellation: token)
            : listThreads(root.path, {}, cancellation: token));
          unawaited(reading.then<void>((_) {}, onError: (Object _) {}));
          await Future.any<void>([busy.future, reading.then<void>((_) => throw TestFailure('A locked read escaped before observing the lock'))]).timeout(const Duration(seconds: 5));
          if (cancel) {
            token.cancel(); await expectLater(reading, throwsA(isA<CancelledException>()));
          } else {
            blocker.execute('ROLLBACK'); blocker.close(); closed = true;
            final result = await reading;
            expect(method == 'read' ? result['thread']['id'] : result['data'].single['id'], 'saved');
          }
        } finally {
          token.cancel(); if (!closed) blocker.close();
          await events.cancel(); port.close(); await root.delete(recursive: true);
        }
      });
    }
  }

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
