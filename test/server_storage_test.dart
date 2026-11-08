// Behavioral ports of Codex state/src/runtime/threads.rs metadata/list/archive contracts.
// Happen retains one writer per SQLite file and canonical per-thread histories.
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CancellationToken cancellation;
  final owners = <IsolateOwner>[];
  setUp(() async { root = await Directory.systemTemp.createTemp('shared-server-store-'); cancellation = CancellationToken(); });
  tearDown(() async {
    for (final owner in owners.reversed) { await owner.close(); }
    owners.clear(); cancellation.cancel(); await root.delete(recursive: true);
  });
  Future<IsolateOwner> open() async {
    final owner = await startServerStore(root.path, cancellation: cancellation); owners.add(owner); return owner;
  }
  Future<IsolateOwner> writer(IsolateOwner catalog, String id, {bool create = true}) async {
    final owner = await startStore(root.path, id, create: create, catalog: catalog.port, cancellation: cancellation);
    owners.add(owner); return owner;
  }
  Future<void> seed(IsolateOwner owner, String id) async {
    final config = {'cwd': root.path, 'provider': 'openai', 'model': 'fixture'};
    await callIsolate(owner.port, 'append', {'type': 'task.created', 'data': config, 'metadata': {'config': config}});
    await callIsolate(owner.port, 'thread.name.set', {'name': 'Thread $id'});
  }

  test('thread metadata updates, archive filters and keyset pages survive catalog restart', () async {
    var catalog = await open();
    final a = await writer(catalog, 'a'), b = await writer(catalog, 'b');
    await seed(a, 'a'); await seed(b, 'b');
    final first = await listThreads(root.path, {'limit': 1, 'sortKey': 'created_at'}, cancellation: cancellation);
    final second = await listThreads(root.path, {'limit': 1, 'cursor': first['nextCursor'], 'cwd': '/ignored'}, cancellation: cancellation);
    expect([first['data'].single['id'], second['data'].single['id']].toSet(), {'a', 'b'});
    expect(second['nextCursor'], isNull);
    await callIsolate(a.port, 'thread.name.set', {'name': 'Updated title'});
    expect((await listThreads(root.path, {'searchTerm': 'updated TITLE'}, cancellation: cancellation))['data'].single['name'], 'Updated title');
    await callIsolate(b.port, 'archive', {'archived': true});
    expect((await listThreads(root.path, {}, cancellation: cancellation))['data'].single['id'], 'a');
    expect((await listThreads(root.path, {'archived': true}, cancellation: cancellation))['data'].single['id'], 'b');
    await a.close(); await b.close(); await catalog.close();
    catalog = await open();
    expect((await listThreads(root.path, {}, cancellation: cancellation))['data'].single['name'], 'Updated title');
    expect((await listThreads(root.path, {'archived': true}, cancellation: cancellation))['data'].single['id'], 'b');
    final restored = await writer(catalog, 'b', create: false);
    await callIsolate(restored.port, 'archive', {'archived': false});
    expect((await listThreads(root.path, {}, cancellation: cancellation))['data'], hasLength(2));
  });

  test('catalogs stay empty until histories are explicitly registered', () async {
    final store = TaskStore(root.path, 'unregistered'), config = {'cwd': root.path, 'provider': 'openai', 'model': 'fixture'};
    try {
      store.append('task.created', config, metadata: {'config': config});
      store.mcpSubscription('save', {'create': true, 'snapshot': {'threadId': 'unregistered',
        'subscription_id': 'a' * 32, 'server': 'events', 'name': 'changed', 'mode': 'poll', 'arguments': {}}});
    } finally { store.close(); }
    var catalog = await open();
    expect((await listThreads(root.path, {}, cancellation: cancellation))['data'], isEmpty);
    expect(await callIsolate(catalog.port, 'mcp.threads', {}), isEmpty);
    await catalog.close();
    catalog = await open();
    expect((await listThreads(root.path, {}, cancellation: cancellation))['data'], isEmpty);
    expect(await callIsolate(catalog.port, 'mcp.threads', {}), isEmpty);
    await writer(catalog, 'unregistered', create: false);
    expect((await listThreads(root.path, {}, cancellation: cancellation))['data'].single['id'], 'unregistered');
    expect(await callIsolate(catalog.port, 'mcp.threads', {}), ['unregistered']);
  });

  test('an interrupted catalog update repairs only its journaled thread from canonical history', () async {
    var catalog = await open(), thread = await writer(catalog, 'thread');
    await seed(thread, 'thread'); await thread.close(); await catalog.close();
    var db = sqlite3.open('${root.path}/server.sqlite');
    db.execute("CREATE TRIGGER fail_enrichment BEFORE UPDATE ON threads WHEN NEW.name IS 'Committed title' "
      "BEGIN SELECT RAISE(ABORT,'injected catalog failure'); END"); db.close();
    catalog = await open(); thread = await writer(catalog, 'thread', create: false);
    await expectLater(callIsolate(thread.port, 'thread.name.set', {'name': 'Committed title'}),
      throwsA(isA<RemoteFailure>().having((error) => error.toString(), 'message', contains('injected catalog failure'))));
    await thread.close(); await catalog.close();
    db = sqlite3.open('${root.path}/server.sqlite');
    expect(db.select('SELECT thread_id FROM dirty_threads').single['thread_id'], 'thread');
    db.execute('DROP TRIGGER fail_enrichment'); db.close();
    catalog = await open();
    expect((await listThreads(root.path, {}, cancellation: cancellation))['data'].single['name'], 'Committed title');
    final read = sqlite3.open('${root.path}/server.sqlite', mode: OpenMode.readOnly);
    try { expect(read.select('SELECT thread_id FROM dirty_threads'), isEmpty); } finally { read.close(); }
  });
}
