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

Future<String> importHistory(
  String directory,
  String source, {
  String? operationId,
  required CancellationToken cancellation,
}) async {
  cancellation.throwIfCancelled();
  final owner = await IsolateOwner.start(_storeMain, {'import_only': true});
  try {
    return await callIsolate(owner.port, 'import', {
      'directory': directory,
      'path': source,
      'operation_id': operationId,
    }, cancellation: cancellation) as String;
  } finally {
    await owner.close();
  }
}

void _storeMain(List<Object?> args) async {
  final config = jsonObject(args[1]);
  final store = config['import_only'] == true
      ? null
      : TaskStore(
          config['directory'] as String,
          config['task_id'] as String,
          create: config['create'] as bool,
          legacyDecoder: config['legacy_decoder'] as LegacyRecordDecoder?,
        );
  final port = ReceivePort(), queue = StreamController<Json>();
  final operations = <String, CancellationToken>{};
  var closing = false;
  final subscription = port.listen((raw) {
    final request = jsonObject(raw);
    final reply = request['reply'] as SendPort?;
    if (request['method'] == 'cancel') {
      operations[request['params']['operation_id']]?.cancel();
      reply?.send({'result': null});
      return;
    }
    if (closing) {
      reply?.send({'error': 'Persistence owner is closing'});
      return;
    }
    if (request['method'] == 'close') {
      closing = true;
      for (final token in operations.values) {
        token.cancel();
      }
    }
    operations[request['operation_id'] as String] = CancellationToken();
    queue.add(request);
  });
  (args[0] as SendPort).send(port.sendPort);
  try {
    // Mutations remain serial. The mailbox processes cancellation while a file
    // transfer or paged search yields, without running a second SQL operation.
    await for (final request in queue.stream) {
      final params = jsonObject(request['params']);
      final reply = request['reply'] as SendPort?;
      final id = request['operation_id'] as String;
      final cancellation = operations[id]!;
      try {
        cancellation.throwIfCancelled();
        final Object? result = switch (request['method']) {
          'append' => store!.append(
            params['type'] as String,
            jsonObject(params['data']),
            metadata: jsonObject(params['metadata'] ?? {}),
          ),
          'append_batch' => store!.appendBatch(
            (params['events'] as List).map(jsonObject).toList(),
            metadata: jsonObject(params['metadata'] ?? {}),
          ),
          'metadata' => store!.metadata(params['key'] as String),
          'context' => store!.modelContext(),
          'history' => store!.history(
            after: params['after'] as int? ?? 0,
            limit: params['limit'] as int? ?? 100,
          ),
          'history.list_windows' => store!.listWindows(params),
          'history.list_items' => await store!.listItems(
            params,
            cancellation: cancellation,
          ),
          'history.read_item' => store!.readItem(params),
          'history.search_contents' => await store!.searchContents(
            params,
            cancellation: cancellation,
          ),
          'fork' =>
            await store!
                .fork(
                  params['id'] as String,
                  through: params['through'] as int?,
                  cancellation: cancellation,
                )
                .then((_) => null),
          'export' =>
            await store!
                .exportTo(params['path'] as String, cancellation: cancellation)
                .then((_) => null),
          'import' => await TaskStore.importFrom(
            params['directory'] as String,
            params['path'] as String,
            operationId: params['operation_id'] as String?,
            cancellation: cancellation,
          ),
          'close' => null,
          _ => throw StateError('Unknown persistence operation'),
        };
        reply?.send({'result': result});
        if (request['method'] == 'close') break;
      } catch (error) {
        reply?.send({
          'error': error.toString(),
          if (error is CancelledException) 'code': 'cancelled',
        });
      } finally {
        operations.remove(id);
        cancellation.cancel();
      }
    }
  } finally {
    store?.close();
    await subscription.cancel();
    port.close();
    unawaited(queue.close());
  }
}
