import 'dart:async';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';

/// Task-owned native tool state survives the short-lived agent/SQLite owners.
/// Each invocation still has its own cancellation; only explicitly persistent
/// processes use the task lifetime inside the provider's runtime.
class TaskToolBridge {
  TaskToolBridge() {
    _mailbox.listen((raw) => unawaited(_handle(jsonObject(raw))));
  }
  final _mailbox = ReceivePort();
  final _tasks = <String, _Tools>{};
  final _operations = <String, CancellationToken>{};
  final _releasing = <String, Future<void>>{};
  bool _closed = false;
  SendPort get port => _mailbox.sendPort;

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
      if (_releasing.containsKey(task)) throw StateError('Task tools are hibernating');
      cancellation = CancellationToken();
      _operations[operation!] = cancellation;
      owner = _tasks[task];
      Object? result;
      if (request['method'] == 'notifications') {
        if (owner != null) owner.pending.add(settled.future);
        result = owner == null ? <String>[] : await owner.runtime.notifications(cancellation: cancellation);
      } else if (request['method'] == 'call') {
        final provider = requiredString(params, 'provider');
        final interface = switch (provider) {
          'openai' => const OpenAIToolInterface(),
          'opencode' => const OpenCodeToolInterface(),
          _ => throw StateError('Unknown task tool interface'),
        };
        owner ??= _tasks[task] = _Tools(interface, requiredString(params, 'cwd'));
        if (owner.provider != interface.id) throw StateError('Task tool interface changed');
        owner.pending.add(settled.future);
        result = await owner.runtime.call(requiredString(params, 'name'), params['arguments'],
          cancellation: cancellation.merge(owner.lifetime), cwd: requiredString(params, 'cwd'));
      } else {
        throw StateError('Unknown task tool operation');
      }
      reply?.send({'result': result});
    } catch (error) {
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

  Future<void> release(String task) => _releasing[task] ??= _release(task).whenComplete(() { _releasing.remove(task); });
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
  final String provider;
  final lifetime = CancellationToken();
  late final ToolRuntime runtime;
  final pending = <Future<void>>{};
}
