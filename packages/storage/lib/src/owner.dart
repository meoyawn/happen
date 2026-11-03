import 'dart:async';
import 'dart:isolate';

import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import '../storage.dart';
import 'session_reader.dart';

Future<IsolateOwner> startStore(
  String directory,
  String id, {
  bool create = true,
  bool inMemory = false,
  Json? fork,
}) => IsolateOwner.start(_storeMain, {
  'directory': directory,
  'task_id': id,
  'create': create,
  'in_memory': inMemory,
  'fork': fork,
}, service: 'storage');

Future<String> importHistory(
  String directory,
  String source, {
  String? operationId,
  required SendPort taskIds,
  required CancellationToken cancellation,
}) async {
  cancellation.throwIfCancelled();
  final owner = await IsolateOwner.start(_storeMain, {'import_only': true}, service: 'storage');
  try {
    return await callIsolate(owner.port, 'import', {
      'directory': directory,
      'path': source,
      'operation_id': operationId,
      'task_ids': taskIds,
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
          inMemory: config['in_memory'] == true,
        );
  if (config['fork'] case final Map snapshot) store!.initializeFork(jsonObject(snapshot));
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
      var closed = false;
      await traceIncoming(request, () async {
      try {
        cancellation.throwIfCancelled();
        if (store != null && {'append', 'append_batch', 'context', 'fork.snapshot', 'session.prepare',
          'session.message.list', 'session.event.list', 'session.inbox',
          'session.inbox.update', 'session.inbox.commit'}.contains(request['method'])) {
          await store.prepareSession(cancellation: cancellation);
        }
        final Object? result = switch (request['method']) {
          'session.prepare' => null,
          'session.inbox.cancel' => store!.discardSessionInbox(requiredString(params, 'reason')),
          'session.inbox.update' => store!.changeSessionInbox(requiredString(params, 'inboxID'), delivery: params['delivery'] as String?),
          'session.inbox.commit' => store!.commitSessionSteering((params['ids'] as List).cast<String>(),
            effort: requiredString(params, 'effort'), reasoningUpdates: params['reasoningUpdates'] == true),
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
          'kv.get' || 'kv.set' || 'kv.remove' || 'kv.scan' => store!.keyValue((request['method'] as String).substring(3), params),
          'archive' => store!.archive(params['archived'] as bool),
          'maintain' => store!.maintain(),
          'context' => store!.modelSnapshot(),
          'fork.snapshot' => store!.forkSnapshot(),
          'session.message.list' || 'session.event.list' || 'session.inbox' =>
            readStoredSession(store!.db, request['method'] as String, params),
          'history' => store!.history(
            after: params['after'] as int? ?? 0,
            limit: params['limit'] as int? ?? 100,
          ),
          'history.list' => store!.historyPage(
            before: params['before'] as int?,
            limit: params['limit'] as int? ?? 100,
          ),
          'history.part' => store!.conversationPart(requiredString(params, 'id')),
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
            newTaskId: (config) async => await callIsolate(
              params['task_ids'] as SendPort, 'task.new_id', {'provider': config['provider']},
              cancellation: cancellation,
            ) as String,
            cancellation: cancellation,
          ),
          'close' => null,
          _ => throw StateError('Unknown persistence operation'),
        };
        reply?.send({'result': result});
        if (request['method'] == 'close') closed = true;
      } catch (error) {
        traceError(error);
        reply?.send({
          'error': error.toString(),
          if (error is CancelledException) 'code': 'cancelled',
        });
      } finally {
        operations.remove(id);
        cancellation.cancel();
      }
      }, service: 'storage');
      if (closed) break;
    }
  } finally {
    store?.close();
    await subscription.cancel();
    port.close();
    unawaited(queue.close());
  }
}
