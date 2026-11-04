import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'new and reopened databases use WAL, NORMAL, and enforce foreign keys',
    () async {
      final root = await Directory.systemTemp.createTemp('storage-pragmas-');
      final id = newId();
      addTearDown(() => root.delete(recursive: true));
      for (final create in [true, false]) {
        final store = TaskStore(root.path, id, create: create);
        try {
          expect(
            {
              for (final pragma in [
                'journal_mode',
                'synchronous',
                'foreign_keys',
              ])
                pragma: store.db.select('PRAGMA $pragma').single[pragma],
            },
            {'journal_mode': 'wal', 'synchronous': 1, 'foreign_keys': 1},
          );
          store.db.execute('''
          CREATE TEMP TABLE fk_parent (id INTEGER PRIMARY KEY);
          CREATE TEMP TABLE fk_child (parent_id INTEGER REFERENCES fk_parent(id));
          INSERT INTO fk_parent VALUES (1);
          INSERT INTO fk_child VALUES (1);
        ''');
          expect(
            () => store.db.execute('DELETE FROM fk_parent WHERE id IS 1'),
            throwsA(
              isA<Exception>().having(
                (error) => error.toString(),
                'constraint error',
                contains('FOREIGN KEY constraint failed'),
              ),
            ),
          );
        } finally {
          store.close();
        }
      }
    },
  );

  test('import writes only its new database and preserves provider IDs', () async {
    final root = await Directory.systemTemp.createTemp('history-import-');
    final source = TaskStore(root.path, newId());
    final legacyId = newId();
    final legacy = TaskStore(root.path, legacyId);
    addTearDown(() async {
      source.close();
      legacy.close();
      await root.delete(recursive: true);
    });
    final config = {'provider': 'opencode', 'model': 'fixture-model'};
    source.append('task.created', config, metadata: {'config': config, 'status': 'idle'});
    legacy.append('task.imported', {}, metadata: {'import_operation': legacyId});
    final bundle = '${root.path}/portable.jsonl';
    await source.exportTo(bundle);
    source.db.execute('BEGIN IMMEDIATE');
    legacy.db.execute('PRAGMA locking_mode = EXCLUSIVE');
    legacy.db.execute('BEGIN EXCLUSIVE');
    try {
      var generated = 0;
      final operationId = newId();
      final imported = await TaskStore.importFrom(root.path, bundle, operationId: operationId,
        newTaskId: (restored) async {
          expect(restored, config);
          generated++;
          return 'ses_ffffffc17ffe0z070z070z070z';
        });
      expect(imported, isNot(operationId));
      expect(generated, 1);
      final restored = TaskStore(root.path, imported, create: false);
      try {
        expect(restored.metadata('config'), config);
        expect(restored.metadata('import_operation'), operationId);
      } finally { restored.close(); }
      expect(Directory('${root.path}/staging').listSync(), isEmpty);
    } finally {
      source.db.execute('ROLLBACK');
      legacy.db.execute('ROLLBACK');
    }
  });


  test('cancelled fork admission preserves the writer and never publishes a child', () async {
    final root = await Directory.systemTemp.createTemp('history-cancel-');
    final owner = await startStore(root.path, newId());
    addTearDown(() async {
      await owner.close();
      await root.delete(recursive: true);
    });
    await callIsolate(owner.port, 'append', {
      'type': 'task.created',
      'data': <String, Object?>{},
    });
    final child = newId(), copying = CancellationToken()..cancel();
    final fork = expectLater(
      callIsolate(owner.port, 'fork', {'id': child}, cancellation: copying),
      throwsA(isA<CancelledException>()),
    );
    await fork;
    // This request queues behind the cancelled copy and its cleanup.
    await callIsolate(owner.port, 'append', {
      'type': 'task.archived',
      'data': {'after_cancel': true},
    });
    expect(await Directory('${root.path}/tasks/$child').exists(), isFalse);
    expect(await callIsolate(owner.port, 'history', {'limit': 1}), hasLength(1));
  });
}
