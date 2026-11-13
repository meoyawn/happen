part of '../server.dart';

// Codex thread_lifecycle.rs::UnloadingState: both the final subscriber and
// active turn must be gone for a full delay. Neither a read nor a repeated
// unsubscribe restarts that countdown.
extension _ThreadLifecycle on AgentServer {
  ({CancellationToken cancellation, Future<void> released}) _threadLifetime(String id) =>
    _threadLifetimes.putIfAbsent(id, () {
      final parent = _tasks[id]?.sideParentID;
      final cancellation = parent == null ? CancellationToken() : CancellationToken().merge(_threadLifetime(parent).cancellation);
      final released = _releaseCancelledThread(id, cancellation);
      // The owner awaits this future when archiving. Observe it immediately so
      // cancellation without a waiting client cannot report an uncaught error.
      unawaited(released.catchError((Object error) { traceError(error); }));
      return (cancellation: cancellation, released: released);
    });

  Future<void> _releaseCancelledThread(String id, CancellationToken cancellation) async {
    try { await Completer<void>().future.asCancellable(cancellation.merge(_lifetime)); }
    on CancelledException { /* Cancellation ends this thread's resource lifetime. */ }
    if (_closing) return; // Server shutdown preserves durable remote watches.
    final task = _tasks[id];
    Object? failure;
    StackTrace? failureStack;
    Future<void> release(Future<void> Function() effect) async {
      try { await effect(); }
      on CancelledException { /* Work belonging to the cancelled thread has drained. */ }
      catch (error, stack) { failure ??= error; failureStack ??= stack; traceError(error); }
    }
    // Stop the network producers independently of local teardown. No saved
    // subscription write is allowed to wait on this thread's maintenance gate.
    final detached = release(() async {
      if (_networkExited) return;
      try {
        await Future.wait([
          callIsolate(network.port, 'agents.forget', {'task_id': id}, cancellation: _lifetime),
          callIsolate(network.port, 'mcp.detach', {'owner': 'thread:$id', 'persist': false}, cancellation: _lifetime),
        ]);
      } on RemoteFailure catch (error) {
        if (!{'worker_exited', 'worker_failed'}.contains(error.code)) rethrow;
      }
    });
    if (task != null) {
      task.cancelled = true;
      task.unloadTimer?.cancel(); task.unloadTimer = null;
      task.goalContinuation?.cancel();
      task.codeInterrupt?.interrupt();
      task.agent?.port.send({'method': 'cancel', 'params': <String, Object?>{}});
      _clientTools.archive(id);
      _questions.release(id);
      await release(() async { await task.running; });
    }
    await release(() async { await _namingThreads[id]; });
    await release(() async { await _mcpDeliveries[id]; });
    await release(() async { await _sideForks[id]; });
    for (final side in _tasks.values.where((side) => side.sideParentID == id).toList()) {
      await release(() => _closeSide(side));
    }
    if (task != null) {
      // Archive owns the final commit. Releasing SQLite waits for that commit
      // and its maintenance gate, even when another cleanup effect failed.
      if (task.archiveCommit case final committed?) { await committed.future; }
      else { while (task.maintenance) { await task.maintenanceDone!.future; } }
      if (task.writerRequests > 0) await (task.writerDrained ??= Completer<void>()).future;
      await release(() async { await task.agent?.close(); });
      task.agent = null;
      task.codeInterrupt?.close(); task.codeInterrupt = null;
    }
    await release(() => _taskTools.release(id));
    if (task != null) {
      final stores = {if (task.writer != null) task.writer!, if (task.memoryStore != null) task.memoryStore!};
      await release(() async { await Future.wait(stores.map((store) => store.close())); });
      task.writer = null; task.memoryStore = null; task.loaded = false;
      task.pending.clear(); task.pendingTraces.clear(); task.mcpInputs.clear(); task.offered.clear();
      _goals.remove(id);
    }
    await detached;
    if (task != null) {
      if (identical(_tasks[id], task)) _tasks.remove(id);
      _notifyThreadStatus(task);
      if (task.sideParentID != null) _broadcast(id, {'type': 'side.closed', 'data': {'parentID': task.sideParentID}});
    }
    for (final client in _clients) {
      client.subscriptions.remove(id);
      client.observations.remove(id);
      client.contextSnapshots.removeWhere((_, snapshot) => snapshot['sessionID'] == id);
      client.sessionTraces.remove(id);
      client.sideCreations.removeWhere((_, side) => side == id);
      client.event({'method': 'thread/closed', 'params': {'threadId': id}});
    }
    _activity.add(activeTaskCount);
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }

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
    cancellation = cancellation.merge(_threadLifetime(id).cancellation);
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
        task.writer ??= await _startStore(id, create: false);
        if (await callIsolate(task.writer!.port, 'metadata', {'key': 'archived_at'}, cancellation: cancellation) != null) {
          throw StateError('Restore this task before loading it');
        }
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
    _threadLifetimes[task.id]?.cancellation.isCancelled != true &&
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
