part of '../server.dart';

// Codex thread_lifecycle.rs::UnloadingState: both the final subscriber and
// active turn must be gone for a full delay. Neither a read nor a repeated
// unsubscribe restarts that countdown.
extension _ThreadLifecycle on AgentServer {
  void _subscribe(_Client client, String id) {
    client.subscriptions.add(id);
    _tasks[id]?.unloadTimer?.cancel();
    _tasks[id]?.unloadTimer = null;
  }

  int _unloadDelay(Json params) {
    final config = params['config'];
    if (config != null && config is! Map) throw const FormatException('config must be an object');
    final delay = (config as Map?)?['thread_unload_delay_secs'];
    if (delay == null) return _threadUnloadDelaySecs;
    if (delay is! int || delay < 0) throw const FormatException('`thread_unload_delay_secs` must be a non-negative integer');
    if (delay > 9223372036854) throw const FormatException('`thread_unload_delay_secs` is too large');
    return delay;
  }

  Future<_Task> _loadThread(String id, CancellationToken cancellation, {Json params = const {}, bool notifyStatus = true}) async {
    while (true) {
      cancellation.throwIfCancelled();
      final task = _tasks[id] ?? _Task(id, null);
      if (task.maintenance || task.finishing || task.busy && task.writer == null) {
        await (task.maintenance ? task.maintenanceDone!.future : task.finishing ? task.running! : task.ready!.future).asCancellable(cancellation);
        continue;
      }
      if (task.loaded) return task;
      final delay = _unloadDelay(params);
      task.maintenance = true;
      final settled = task.maintenanceDone = Completer<void>();
      _tasks[id] = task;
      try {
        task.writer ??= await startStore(directory, id, create: false);
        task.config ??= jsonObject(await callIsolate(task.writer!.port, 'metadata', {'key': 'config'}, cancellation: cancellation));
        final inbox = jsonObject(await callIsolate(task.writer!.port, 'session.inbox', {}, cancellation: cancellation));
        task.pending..clear()..addAll((inbox['data'] as List).map(jsonObject));
        cancellation.throwIfCancelled();
        task.loaded = true;
        task.unloadDelaySecs = delay;
        if (_goalsEnabled(task.config!)) _loadedGoalRuntime(task);
        if (notifyStatus) _notifyThreadStatus(task);
        return task;
      } finally {
        if (!task.loaded) { await task.writer?.close(); task.writer = null; }
        task.maintenance = false; task.maintenanceDone = null; settled.complete();
        _forgetIdle(task);
      }
    }
  }

  Json _threadStatus(_Task? task) => {'type': task?.loaded != true ? 'notLoaded'
    : task!.busy ? 'active' : task.systemError ? 'systemError' : 'idle',
    if (task?.busy == true) 'activeFlags': <String>[]};

  void _notifyThreadStatus(_Task task) {
    final notification = {'method': 'thread/status/changed', 'params': {'threadId': task.id, 'status': _threadStatus(task)}};
    for (final client in _clients) { client.event(notification); }
  }

  bool _canUnload(_Task task) => task.loaded && !task.busy && !task.disposing && task.eventAdmissions == 0 &&
    !_clients.any((client) => client.subscriptions.contains(task.id));

  void _scheduleUnload(_Task task) {
    if (_closing || !_canUnload(task)) {
      task.unloadTimer?.cancel(); task.unloadTimer = null;
      return;
    }
    task.unloadTimer ??= Timer(Duration(seconds: task.unloadDelaySecs), () {
      task.unloadTimer = null;
      final operation = _unloadIdle(task);
      _requests.add(operation);
      unawaited(operation.catchError((Object error) { traceError(error); }).whenComplete(() => _requests.remove(operation)));
    });
  }

  Future<void> _unloadIdle(_Task task) async {
    while (!_closing && identical(_tasks[task.id], task) && _canUnload(task)) {
      if (task.maintenance) {
        await task.maintenanceDone!.future.asCancellable(_lifetime);
        continue;
      }
      task.goalContinuation?.cancel();
      task.maintenance = true;
      final settled = task.maintenanceDone = Completer<void>();
      try {
        if (task.writerRequests > 0) await (task.writerDrained ??= Completer<void>()).future.asCancellable(_lifetime);
        await _taskTools.release(task.id);
        _clientTools.archive(task.id);
        _goals.remove(task.id);
        if (!_networkExited) await callIsolate(network.port, 'agents.forget', {'task_id': task.id}, cancellation: _lifetime);
        await (task.memoryStore ?? task.writer)?.close();
        task.writer = null; task.memoryStore = null;
        task.loaded = false;
        _tasks.remove(task.id);
        _notifyThreadStatus(task);
        for (final client in _clients) {
          client.event({'method': 'thread/closed', 'params': {'threadId': task.id}});
        }
      } finally {
        task.maintenance = false; task.maintenanceDone = null; settled.complete();
      }
      return;
    }
  }
}
