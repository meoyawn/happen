import 'dart:async';
import 'dart:isolate';

import 'package:protocol/protocol.dart';

import 'cancellation.dart';
import 'quickjs.dart';

/// The interpreter runs in this process, independently of its observer's clock.
/// Host effects stay with their owner; only JSON and the atomic signal cross.
Future<Json> runCell(String source, {
  required HostTool tool,
  required CodeCancellationToken cancellation,
  required Json values,
  required List<Json> catalog,
  required String id,
  required void Function(Json) onEvent,
  Future<void> Function(String)? notify,
}) async {
  final port = ReceivePort(), lifetime = CancellationToken();
  final link = CancellationHook(cancellation, lifetime.cancel);
  final operations = <String, CancellationToken>{};
  final pending = <Future<void>>{};
  Object? eventFailure;
  StackTrace? eventStack;
  Future<void> handle(Json request) async {
    final reply = request['reply'] as SendPort;
    final operation = request['operation_id'] as String;
    final token = CancellationToken();
    final hook = CancellationHook(lifetime, token.cancel);
    operations[operation] = token;
    try {
      token.throwIfCancelled();
      final params = jsonObject(request['params']);
      final Object? result;
      if (request['method'] == 'notify') {
        await notify?.call(params['text'] as String).asCancellable(token);
        result = null;
      } else {
        result = await tool(params['name'] as String, params['arguments'], cancellation: token);
      }
      reply.send({'result': result});
    } catch (error) {
      reply.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
    } finally {
      operations.remove(operation);
      hook.dispose();
      token.cancel();
    }
  }
  final listener = port.listen((raw) {
    final request = jsonObject(raw);
    if (request['method'] == 'cancel') {
      operations[request['params']['operation_id']]?.cancel();
      return;
    }
    late final Future<void> running;
    running = handle(request).whenComplete(() => pending.remove(running));
    pending.add(running);
  });
  try {
    return await runIsolateEffect<Json>(_executeCell, {
      'source': source, 'values': values, 'catalog': catalog, 'cell_id': id,
      'host': port.sendPort, 'interrupt': cancellation.address, 'generation': cancellation.generation,
    }, cancellation: cancellation, timeout: null, onEvent: (event) {
      try { onEvent(event); }
      catch (error, stack) {
        eventFailure ??= error;
        eventStack ??= stack;
        cancellation.cancel();
      }
    });
  } catch (error, stack) {
    Error.throwWithStackTrace(eventFailure ?? error, eventStack ?? stack);
  } finally {
    lifetime.cancel();
    await Future.wait(pending.toList());
    link.dispose();
    await listener.cancel();
    port.close();
  }
}

Future<Json> _executeCell(Json params, CancellationToken lifetime, void Function(Json) event) async {
  final cancellation = CodeCancellationToken.shared(params['interrupt'] as int, generation: params['generation'] as int);
  final link = CancellationHook(lifetime, cancellation.cancel);
  final engine = QuickJs(memoryLimit: 256 * 1024 * 1024);
  final host = params['host'] as SendPort;
  try {
    Json result;
    try {
      result = await engine.run(params['source'] as String,
        values: jsonObject(params['values']), catalog: (params['catalog'] as List).cast<Json>(),
        cancellation: cancellation, awaitPending: false, retainOutput: true,
        module: true, cellId: params['cell_id'] as String, onEvent: event,
        onNotify: (text) async {
          await callIsolate(host, 'notify', {'text': text}, cancellation: cancellation, timeout: null);
        },
        tool: (name, arguments, {required cancellation}) => callIsolate(host, 'tool',
          {'name': name, 'arguments': arguments}, cancellation: cancellation, timeout: null));
    } catch (error) {
      result = {'error': error is StateError ? error.message : error.toString()};
    }
    if (!cancellation.isCancelled && !result.containsKey('writes')) {
      try { result['writes'] = jsonObject(engine.evaluate('__cell.writes')); }
      catch (error) { result.putIfAbsent('error', () => error.toString()); }
    }
    return result;
  } finally {
    engine.close();
    link.dispose();
    cancellation.close();
  }
}
