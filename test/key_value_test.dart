import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('session KV stores JSON in the session database and scans literal namespaced prefixes across reopen', () async {
    final root = await Directory.systemTemp.createTemp('session-kv-');
    final id = newUuidV7();
    var owner = await startStore(root.path, id);
    addTearDown(() async { await owner.close(); await root.delete(recursive: true); });
    Future<Object?> call(String method, Json arguments) => callIsolate(owner.port, 'kv.$method', arguments);
    await call('set', {'key': 'plugin:0061:a%_:α', 'value': {'ordered': [3, 1, 2]}});
    await call('set', {'key': 'plugin:0061:a%_:β', 'value': null});
    await call('set', {'key': 'plugin:0061:a%_:γ', 'value': 'tail'});
    await call('set', {'key': 'plugin:0061:axxx:δ', 'value': 'not a literal-prefix match'});
    await call('set', {'key': 'plugin:0062:a%_:α', 'value': false});
    await owner.close();
    owner = await startStore(root.path, id, create: false);
    expect(await call('get', {'key': 'plugin:0061:a%_:α'}), {'ordered': [3, 1, 2]});
    final first = jsonObject(await call('scan', {'prefix': 'plugin:0061:a%_:', 'limit': 2}));
    expect(first['entries'], [
      {'key': 'plugin:0061:a%_:α', 'value': {'ordered': [3, 1, 2]}},
      {'key': 'plugin:0061:a%_:β', 'value': null},
    ]);
    expect(await call('scan', {'prefix': 'plugin:0061:a%_:', 'after': first['next'], 'limit': 2}), {
      'entries': [{'key': 'plugin:0061:a%_:γ', 'value': 'tail'}],
    });
    await call('set', {'key': 'plugin:0061:a%_:γ', 'value': 42});
    await call('remove', {'key': 'plugin:0061:a%_:α'});
    expect(await call('get', {'key': 'plugin:0061:a%_:α'}), isNull);
    expect(await call('get', {'key': 'plugin:0062:a%_:α'}), false);
    final session = TaskStore(root.path, id, create: false);
    try {
      expect(session.db.select('SELECT value FROM kv WHERE key IS ?', ['plugin:0061:a%_:γ']).single['value'], '42');
    } finally { session.close(); }
  });
}
