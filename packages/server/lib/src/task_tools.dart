import 'dart:async';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';
import 'package:storage/src/codex_native.dart' show projectedCodexItem;
import 'package:telemetry/telemetry.dart';

/// Task-owned native tool state survives the short-lived agent/SQLite owners.
/// Each invocation still has its own cancellation; only explicitly persistent
/// processes use the task lifetime inside the provider's runtime.
class TaskToolBridge {
  TaskToolBridge(this.emit) {
    _mailbox.listen((raw) => unawaited(traceIncoming(jsonObject(raw),
      () => _handle(jsonObject(raw)), service: 'server')));
  }
  final void Function(String, Json) emit;
  final _mailbox = ReceivePort();
  final _tasks = <String, _Tools>{};
  final _operations = <String, CancellationToken>{};
  final _releasing = <String, Future<void>>{};
  bool _closed = false;
  SendPort get port => _mailbox.sendPort;

  _Tools _owner(String task, String provider, String cwd) {
    if (_closed) throw StateError('Task tools are closed');
    if (_releasing.containsKey(task)) throw StateError('Thread tools are unloading');
    final owner = _tasks.putIfAbsent(task, () => _Tools(switch (provider) {
      'openai' => const OpenAIToolInterface(),
      'opencode' => const OpenCodeToolInterface(),
      _ => throw StateError('Unknown task tool interface'),
    }, cwd));
    if (owner.provider != provider) throw StateError('Task tool interface changed');
    return owner;
  }

  Future<List<Json>> prepare(String task, String provider, String cwd, SendPort writer, {
    required CancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final owner = _owner(task, provider, cwd);
    owner.writer = writer;
    return (await callIsolate(writer, 'tool_runtime.start', {'id': owner.id},
      cancellation: cancellation) as List).map(jsonObject).toList();
  }

  Future<void> _handle(Json request) async {
    final reply = request['reply'] as SendPort?;
    final params = jsonObject(request['params']);
    final operation = request['operation_id'] as String?;
    CancellationToken? cancellation;
    _Tools? owner;
    final settled = Completer<void>();
    try {
      if (request['method'] == 'cancel') {
        _operations[params['operation_id']]?.cancel();
        reply?.send({'result': null});
        return;
      }
      if (_closed) throw StateError('Task tools are closed');
      final task = requiredString(params, 'task_id');
      if (_releasing.containsKey(task)) throw StateError('Thread tools are unloading');
      cancellation = CancellationToken();
      _operations[operation!] = cancellation;
      owner = _tasks[task];
      Object? result;
      if (request['method'] == 'notifications') {
        if (owner != null) owner.pending.add(settled.future);
        result = owner == null ? <String>[] : await owner.runtime.notifications(cancellation: cancellation);
      } else if (request['method'] == 'call') {
        final provider = requiredString(params, 'provider');
        owner = _owner(task, provider, requiredString(params, 'cwd'));
        owner.pending.add(settled.future);
        final runtime = owner;
        var foreground = true;
        try {
          result = await runtime.runtime.call(requiredString(params, 'name'), params['arguments'],
            cancellation: cancellation.merge(runtime.lifetime), cwd: requiredString(params, 'cwd'),
            callId: params['call_id'] as String?, onItem: (phase, item) async {
              final data = <String, dynamic>{'turnId': params['turn_id'], 'item': projectedCodexItem(item),
                'canonicalItem': item, if (phase == 'completed') 'completedAtMs': DateTime.now().millisecondsSinceEpoch};
              if (phase == 'completed' && foreground) {
                // Admit to the writer's memory queue. Its next ordinary record
                // (including cancellation) durably flushes this completion in
                // that same transaction, before broadcasting it to clients.
                await callIsolate(runtime.writer!, 'native.item.queue', data);
              } else {
                final record = jsonObject(await callIsolate(runtime.writer!, 'append', {
                  'type': 'native.item.$phase', 'data': data,
                }));
                emit(task, record);
              }
            });
        } finally { foreground = false; }
      } else {
        throw StateError('Unknown task tool operation');
      }
      reply?.send({'result': result});
    } catch (error) {
      traceError(error);
      reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
    } finally {
      _operations.remove(operation);
      cancellation?.cancel();
      owner?.pending.remove(settled.future);
      settled.complete();
    }
  }

  Future<void> settle(String task) async {
    final owner = _tasks[task];
    if (owner != null) await Future.wait(owner.pending.toList());
  }

  Future<void> release(String task) => _releasing[task] ??= _release(task).whenComplete(() { unawaited(_releasing.remove(task)); });
  Future<void> _release(String task) async {
    final owner = _tasks.remove(task);
    if (owner == null) return;
    owner.lifetime.cancel();
    await owner.runtime.close();
    await Future.wait(owner.pending.toList());
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(_tasks.keys.toList().map(release));
    await Future.wait(_releasing.values.toList());
    _mailbox.close();
  }
}

class _Tools {
  _Tools(ToolInterface interface, String cwd) : provider = interface.id {
    runtime = interface.createRuntime(cwd, lifetime);
  }
  final id = newId();
  final String provider;
  final lifetime = CancellationToken();
  late final ToolRuntime runtime;
  SendPort? writer;
  final pending = <Future<void>>{};
}
