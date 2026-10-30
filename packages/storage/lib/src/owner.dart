import 'dart:async';
import 'dart:isolate';

import 'package:protocol/protocol.dart';

import '../storage.dart';

Future<IsolateOwner> startStore(
  String directory,
  String id, {
  bool create = true,
  LegacyRecordDecoder? legacyDecoder,
}) => IsolateOwner.start(_storeMain, {
  'directory': directory,
  'task_id': id,
  'create': create,
  'legacy_decoder': legacyDecoder,
});

void _storeMain(List<Object?> args) async {
  final config = jsonObject(args[1]);
  final store = TaskStore(
    config['directory'] as String,
    config['task_id'] as String,
    create: config['create'] as bool,
    legacyDecoder: config['legacy_decoder'] as LegacyRecordDecoder?,
  );
  final port = ReceivePort();
  (args[0] as SendPort).send(port.sendPort);
  try {
    // await-for drains one request at a time, including async export/fork.
    await for (final raw in port) {
      final request = jsonObject(raw),
          params = jsonObject(jsonObject(raw)['params']);
      final reply = request['reply'] as SendPort;
      try {
        final Object? result = switch (request['method']) {
          'append' => store.append(
            params['type'] as String,
            jsonObject(params['data']),
            metadata: jsonObject(params['metadata'] ?? {}),
          ),
          'append_batch' => store.appendBatch(
            (params['events'] as List).map(jsonObject).toList(),
            metadata: jsonObject(params['metadata'] ?? {}),
          ),
          'metadata' => store.metadata(params['key'] as String),
          'context' => store.modelContext(),
          'history' => store.history(
            after: params['after'] as int? ?? 0,
            limit: params['limit'] as int? ?? 100,
          ),
          'history.list_windows' => store.listWindows(params),
          'history.list_items' => store.listItems(params),
          'history.read_item' => store.readItem(params),
          'history.search_contents' => store.searchContents(params),
          'fork' =>
            await store
                .fork(
                  params['id'] as String,
                  through: params['through'] as int?,
                )
                .then((_) => null),
          'export' =>
            await store.exportTo(params['path'] as String).then((_) => null),
          'close' => null,
          _ => throw StateError('Unknown persistence operation'),
        };
        reply.send({'result': result});
        if (request['method'] == 'close') break;
      } catch (error) {
        reply.send({'error': error.toString()});
      }
    }
  } finally {
    store.close();
    port.close();
  }
}
