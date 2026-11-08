import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import '../storage.dart';
import 'session_reader.dart';

// One writer isolate owns each saved session. Reserve the canonical file before
// spawning so simultaneous requests/aliases cannot open another writer.
final _writers = <String>{};
Future<IsolateOwner> startStore(String directory, String id, {bool create = true, bool inMemory = false, Json? fork,
    SendPort? catalog, CancellationToken? cancellation}) async {
  validateTaskId(id);
  final folder = Directory(directory);
  if (create && !inMemory) await folder.create(recursive: true);
  final canonical = await folder.exists() ? await folder.resolveSymbolicLinks() : folder.absolute.path;
  final file = File('$canonical/tasks/$id/history.sqlite');
  final key = inMemory ? 'memory:$canonical:$id' : await file.exists() ? await file.resolveSymbolicLinks() : file.path;
  if (!_writers.add(key)) throw StateError('Thread $id already has an active writer');
  IsolateOwner? owner;
  try {
    final shared = inMemory ? null : catalog;
    final ticket = shared == null ? null : await callIsolate(shared, 'thread.dirty', {'threadId': id}, cancellation: cancellation);
    owner = await IsolateOwner.start(_storeMain, {'directory': canonical, 'task_id': id, 'create': create,
      'in_memory': inMemory, 'fork': fork, 'catalog': shared}, service: 'storage');
    unawaited(owner.done.whenComplete(() => _writers.remove(key)));
    if (shared != null) await callIsolate(owner.port, 'catalog.sync', {'ticket': ticket}, cancellation: cancellation);
    return owner;
  } catch (_) { try { await owner?.close(); } finally { _writers.remove(key); } rethrow; }
}

Future<String> importHistory(String directory, String source, {String? operationId, required SendPort taskIds,
    SendPort? catalog, required CancellationToken cancellation}) async {
  cancellation.throwIfCancelled();
  final owner = await IsolateOwner.start(_storeMain, {'import_only': true, 'catalog': catalog}, service: 'storage');
  try {
    return await callIsolate(owner.port, 'import', {'directory': directory, 'path': source, 'operation_id': operationId,
      'task_ids': taskIds}, cancellation: cancellation) as String;
  } finally { await owner.close(); }
}

Future<void> _storeMain(List<Object?> args) async {
  final config = jsonObject(args[1]);
  final store = config['import_only'] == true ? null : TaskStore(requiredString(config, 'directory'), requiredString(config, 'task_id'),
    create: config['create'] == true, inMemory: config['in_memory'] == true);
  try {
    if (config['fork'] case final Map<Object?, Object?> snapshot) store!.initializeFork(jsonObject(snapshot));
  } catch (_) { store?.close(); rethrow; }
  final port = ReceivePort(), queue = StreamController<Json>(), operations = <String, CancellationToken>{};
  var closing = false;
  final listener = port.listen((raw) {
    final request = jsonObject(raw), reply = request['reply'] as SendPort?;
    if (request['method'] == 'cancel') { operations[request['params']['operation_id']]?.cancel(); reply?.send({'result': null}); return; }
    if (closing) { reply?.send({'error': 'Persistence owner is closing'}); return; }
    if (request['method'] == 'close') { closing = true; for (final token in operations.values) { token.cancel(); } }
    operations[requiredString(request, 'operation_id')] = CancellationToken(); queue.add(request);
  });
  (args[0] as SendPort).send(port.sendPort);
  try {
    // The mailbox admits cancellation while this one writer serializes writes.
    await for (final request in queue.stream) {
      final params = jsonObject(request['params']), reply = request['reply'] as SendPort?;
      final id = requiredString(request, 'operation_id'), cancellation = operations[id]!;
      var stopped = false;
      await traceIncoming(request, () async {
        try {
          cancellation.throwIfCancelled();
          final result = await _storeRequest(store, requiredString(request, 'method'), params, cancellation,
            catalog: config['catalog'] as SendPort?);
          reply?.send({'result': result}); stopped = request['method'] == 'close';
        } catch (error) {
          traceError(error); reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
        } finally { operations.remove(id); cancellation.cancel(); }
      }, service: 'storage');
      if (stopped) break;
    }
  } finally { store?.close(); await listener.cancel(); port.close(); unawaited(queue.close()); }
}

// Enter a fresh handler for every request. The owner's suspended mailbox loop
// survives hot reload, so it must not retain calls to changed storage methods.
Future<Object?> _storeRequest(TaskStore? store, String method, Json params, CancellationToken cancellation, {SendPort? catalog}) async {
  if (method == 'catalog.sync') {
    if (catalog != null) await _syncCatalog(catalog, catalogThread(store!.db, store.directory, store.taskId),
      requiredString(params, 'ticket'), cancellation);
    return null;
  }
  final mutating = const {'session.prepare', 'tool_runtime.start', 'session.inbox.cancel', 'session.inbox.update',
    'session.inbox.commit', 'append', 'append_batch', 'thread.name.set', 'mcp.subscription.save',
    'mcp.subscription.remove', 'mcp.event.admit', 'archive', 'fork'}.contains(method) || method.startsWith('goal.');
  final ticket = catalog == null || store == null || !mutating ? null
    : await callIsolate(catalog, 'thread.dirty', {'threadId': store.taskId}, cancellation: cancellation) as String;
  final childTicket = catalog == null || method != 'fork' ? null
    : await callIsolate(catalog, 'thread.dirty', {'threadId': params['id']}, cancellation: cancellation) as String;
  if (store != null && method == 'session.prepare') await store.prepareSession(cancellation: cancellation);
  final result = await (switch (method) {
    'session.prepare' => null,
    'tool_runtime.start' => store!.startToolRuntime(requiredString(params, 'id')),
    'native.item.queue' => store!.queueNativeCompletion(params),
    'session.inbox.cancel' => store!.discardSessionInbox(requiredString(params, 'reason')),
    'session.inbox.update' => store!.changeSessionInbox(requiredString(params, 'inboxID'), delivery: params['delivery'] as String?),
    'session.inbox.commit' => store!.commitSessionSteering((params['ids'] as List).cast<String>(),
      effort: requiredString(params, 'effort'), reasoningUpdates: params['reasoningUpdates'] == true),
    'append' => store!.append(params['type'] as String, jsonObject(params['data']), metadata: jsonObject(params['metadata'] ?? {})),
    'append_batch' => store!.appendBatch((params['events'] as List).map(jsonObject).toList(), metadata: jsonObject(params['metadata'] ?? {})),
    'metadata' => store!.metadata(params['key'] as String),
    'thread.name.set' => store!.setThreadName(requiredString(params, 'name'), onlyIfUnnamed: params['onlyIfUnnamed'] == true),
    'mcp.subscription.save' => store!.mcpSubscription('save', params),
    'mcp.subscription.remove' => store!.mcpSubscription('remove', params),
    'mcp.event.admit' => store!.admitMcpEvent(params),
    final String method when method.startsWith('goal.') => store!.goal(method.substring(5), params),
    'kv.get' || 'kv.set' || 'kv.remove' || 'kv.scan' => store!.keyValue(method.substring(3), params),
    'archive' => store!.archive(params['archived'] as bool),
    'maintain' => store!.maintain(),
    'context' => store!.modelSnapshot(),
    'fork.snapshot' => store!.forkSnapshot(lastTurnId: params['lastTurnId'] as String?, beforeTurnId: params['beforeTurnId'] as String?),
    'session.usage' => store!.forkUsage(),
    'thread/read' || 'thread/items/list' || 'thread/turns/list' || 'thread/boundary' || 'thread/image/read' || 'session.inbox' =>
      readStoredSession(store!.db, method, params, directory: store.directory, id: store.taskId),
    'history' => store!.rolloutPage(params),
    'history.list_windows' || 'history.list_items' || 'history.read_item' || 'history.search_contents' =>
      await store!.recall(method, params, cancellation: cancellation),
    'fork' => await store!.fork(params['id'] as String, lastTurnId: params['lastTurnId'] as String?,
      beforeTurnId: params['beforeTurnId'] as String?, configuration: params['configuration'] as Json?,
      cancellation: cancellation).then((_) => null),
    'export' => await store!.exportTo(params['path'] as String, cancellation: cancellation).then((_) => null),
    'import' => await _importStored(params, catalog, cancellation),
    'close' => null,
    _ => throw StateError('Unknown persistence operation'),
  });
  if (ticket != null) await _syncCatalog(catalog!, catalogThread(store!.db, store.directory, store.taskId), ticket, cancellation);
  if (childTicket != null) {
    final rows = await readCatalogThreads(store!.directory, [requiredString(params, 'id')], cancellation: cancellation);
    for (final row in rows) { await _syncCatalog(catalog!, row, childTicket, cancellation); }
  }
  return result;
}

Future<void> _syncCatalog(SendPort catalog, Json row, String ticket, CancellationToken cancellation) async {
  await callIsolate(catalog, 'thread.sync', {'row': row, 'ticket': ticket}, cancellation: cancellation);
}

Future<String> _importStored(Json params, SendPort? catalog, CancellationToken cancellation) async {
  String? ticket;
  final directory = requiredString(params, 'directory');
  final id = await TaskStore.importFrom(directory, requiredString(params, 'path'),
    operationId: params['operation_id'] as String?, newTaskId: (config) async {
      final id = await callIsolate(params['task_ids'] as SendPort, 'task.new_id', {'provider': config['provider']}, cancellation: cancellation) as String;
      if (catalog != null) ticket = await callIsolate(catalog, 'thread.dirty', {'threadId': id}, cancellation: cancellation) as String;
      return id;
    }, cancellation: cancellation);
  if (catalog != null) {
    ticket ??= await callIsolate(catalog, 'thread.dirty', {'threadId': id}, cancellation: cancellation) as String;
    for (final row in await readCatalogThreads(directory, [id], cancellation: cancellation)) {
      await _syncCatalog(catalog, row, ticket!, cancellation);
    }
  }
  return id;
}
