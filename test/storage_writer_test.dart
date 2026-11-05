// One production writer isolate per saved session. Independent sessions use
// different SQLite files; tests never open competing writers on one file.
import 'dart:async';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  final owners = <IsolateOwner>[];
  setUp(() async { root = await Directory.systemTemp.createTemp('storage-writers-'); });
  tearDown(() async { await Future.wait(owners.map((owner) => owner.close())); owners.clear(); await root.delete(recursive: true); });
  Future<IsolateOwner> open(String id, {String? directory, bool create = true}) async {
    final owner = await startStore(directory ?? root.path, id, create: create); owners.add(owner); return owner;
  }
  Future<void> seed(IsolateOwner owner, String id) async {
    await callIsolate(owner.port, 'append', {'type': 'task.created', 'data': {'cwd': root.path},
      'metadata': {'config': {'cwd': root.path, 'provider': 'openai', 'model': id}}});
  }

  test('different saved sessions retain independent SQLite state', () async {
    final first = await open('first'), second = await open('second'); await seed(first, 'first'); await seed(second, 'second');
    expect(first.port, isNot(second.port));
    await Future.wait([callIsolate(first.port, 'kv.set', {'key': 'value', 'value': 'first'}), callIsolate(second.port, 'kv.set', {'key': 'value', 'value': 'second'})]);
    expect(await callIsolate(first.port, 'kv.get', {'key': 'value'}), 'first');
    expect(await callIsolate(second.port, 'kv.get', {'key': 'value'}), 'second');
    for (final id in ['first', 'second']) {
      expect(File('${root.path}/tasks/$id/history.sqlite').existsSync(), true);
      expect(File('${root.path}/tasks/$id/writer.lock').existsSync(), false);
    }
  });

  test('duplicate session ownership is rejected before opening another writer', () async {
    final first = await open('thread'); await seed(first, 'thread');
    await expectLater(startStore(root.path, 'thread', create: false), throwsStateError);
    expect(jsonObject(await callIsolate(first.port, 'metadata', {'key': 'config'}))['model'], 'thread');
  });

  test('canonical directory aliases cannot create a second writer', () async {
    final alias = '${root.path}/alias'; await Link(alias).create(root.path);
    final first = await open('thread'); await seed(first, 'thread');
    await expectLater(startStore(alias, 'thread', create: false), throwsStateError);
    expect(jsonObject(await callIsolate(first.port, 'metadata', {'key': 'config'}))['model'], 'thread');
  }, skip: Platform.isWindows ? 'Symlink creation requires separate Windows privileges.' : false);

  test('closing and reopening one session preserves its data and leaves another session alone', () async {
    final first = await open('first'), second = await open('second'); await seed(first, 'first'); await seed(second, 'second');
    await first.close();
    await callIsolate(second.port, 'kv.set', {'key': 'live', 'value': true});
    final reopened = await open('first', create: false);
    expect(jsonObject(await callIsolate(reopened.port, 'metadata', {'key': 'config'}))['model'], 'first');
    expect(await callIsolate(second.port, 'kv.get', {'key': 'live'}), true);
  });

  test('concurrent read-only connections do not open or replace a writer', () async {
    final writer = await open('thread'); await seed(writer, 'thread');
    final token = CancellationToken();
    try {
      final reads = await Future.wait([for (var index = 0; index < 8; index++) readSession(root.path, 'thread', 'thread/read', {}, cancellation: token)]);
      expect(reads.map((read) => read['thread']['id']), everyElement('thread'));
      await callIsolate(writer.port, 'kv.set', {'key': 'after_reads', 'value': true});
      expect(await callIsolate(writer.port, 'kv.get', {'key': 'after_reads'}), true);
      await expectLater(startStore(root.path, 'thread', create: false), throwsStateError);
    } finally { token.cancel(); }
  });

  test('failed initialization closes its connection and leaves a different session alone', () async {
    final healthy = await open('healthy'); await seed(healthy, 'healthy');
    await Directory('${root.path}/tasks/broken').create();
    final path = '${root.path}/tasks/broken/history.sqlite', broken = sqlite3.open('${root.path}/tasks/broken/history.sqlite');
    broken.execute('PRAGMA journal_mode=WAL'); broken.execute('CREATE TABLE happen_runtime(wrong_column TEXT)'); broken.close();
    await expectLater(startStore(root.path, 'broken', create: false), throwsStateError);
    // Only after failed initialization returns: no concurrent writer on this
    // separate database, and no open failed transaction left in the worker.
    final independent = sqlite3.open(path);
    try { independent.execute('CREATE TABLE after_failed_initialization(value TEXT)'); }
    finally { independent.close(); }
    await callIsolate(healthy.port, 'kv.set', {'key': 'still_live', 'value': true});
    expect(await callIsolate(healthy.port, 'kv.get', {'key': 'still_live'}), true);
  });
}
