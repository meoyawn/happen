part of '../server.dart';

extension _Goals on AgentServer {
  bool _goalsEnabled(Json config) => config['ephemeral'] != true && config['tool_interface'] == 'openai';

  Future<Object?> _goalStore(String id, String method, Json args, CancellationToken token) async {
    while (true) {
      final task = _tasks[id] ?? _Task(id, null);
      // Maintenance awaits this turn. Its final usage must drain through the
      // existing writer before the writer can be archived or released.
      final ownsTurnWriter = task.busy && task.writer != null;
      if (task.finishing || task.busy && task.writer == null || task.maintenance && !ownsTurnWriter) {
        await (task.maintenance ? task.maintenanceDone!.future : task.finishing ? task.running! : task.ready!.future).asCancellable(token);
        continue;
      }
      return await _withWriter(task, (writer) => callIsolate(writer.port, method, args, cancellation: token),
        allowShutdown: task.busy, allowMaintenance: ownsTurnWriter);
    }
  }

  GoalRuntime _makeGoalRuntime(String id, Json config, {required bool loaded}) => GoalRuntime(
    threadId: id, maxTokenBudget: config['provider_settings']?['max_goal_token_budget'] as int?,
    persistent: config['side_parent_id'] == null,
    store: (method, args, token) => _goalStore(id, method, args, token),
    notify: (event) => _broadcast(id, event),
    inject: (record, token) async {
      if (_tasks[id]?.agent case final agent?) {
        await callIsolate(agent.port, 'inject', record, cancellation: token);
      }
    },
    admitContinuation: loaded ? (item) {
      final task = _tasks[id];
      if (_closing || task == null || task.busy || task.maintenance || task.cancelled || task.disposing || task.pending.isNotEmpty) return false;
      try {
        _begin(task, '', settings: {'goalContinuation': true, 'goalItem': item, 'turnId': newUuidV7()});
        return true;
      } catch (_) { return false; }
    } : null,
  );

  GoalRuntime _loadedGoalRuntime(_Task task) {
    _tasks[task.id] = task;
    return _goals.putIfAbsent(task.id, () => _makeGoalRuntime(task.id, task.config!, loaded: true));
  }

  Future<void> _continueGoal(String id) async {
    final runtime = _goals[id], task = _tasks[id];
    if (runtime == null || task == null || _closing || task.busy || task.maintenance || task.cancelled ||
        task.disposing || task.pending.isNotEmpty || task.goalContinuation != null) return;
    final cancellation = task.goalContinuation = CancellationToken();
    try { await runtime.call('continuation', {}, cancellation: cancellation.merge(_threadLifetime(id).cancellation).merge(_lifetime)); }
    on CancelledException { /* Shutdown/maintenance never admits more work. */ }
    catch (error) { traceError(error); }
    finally { if (identical(task.goalContinuation, cancellation)) task.goalContinuation = null; cancellation.cancel(); }
  }

  Future<void> _handleGoalRequest(Object? raw) async {
    final request = jsonObject(raw), params = jsonObject(request['params']);
    final reply = request['reply'] as SendPort?;
    if (request['method'] == 'cancel') {
      _goalOperations[params['operation_id']]?.cancel(); reply?.send({'result': null}); return;
    }
    final operation = requiredString(request, 'operation_id'), token = _goalOperations[requiredString(request, 'operation_id')] = CancellationToken();
    try {
      final task = _tasks[requiredString(params, 'task_id')];
      if (task?.config == null || !_goalsEnabled(task!.config!)) throw StateError('goals feature is disabled');
      final runtime = _loadedGoalRuntime(task);
      reply?.send({'result': await runtime.call(requiredString(request, 'method'), jsonObject(params['arguments'] ?? {}), cancellation: token)});
    } catch (error) {
      reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
    } finally { _goalOperations.remove(operation); token.cancel(); }
  }

  Future<Object?> _threadGoalRequest(String method, String id, Json params, _Client client, Object requestId, CancellationToken token) async {
    final resident = _tasks[id];
    final config = resident?.config ?? jsonObject(await _goalStore(id, 'metadata', {'key': 'config'}, token));
    if (!_goalsEnabled(config)) throw const FormatException('goals feature is disabled');
    if (method == 'thread/goal/get') {
      final result = await _goalStore(id, 'goal.get', {}, token);
      return {'goal': result == null ? null : protocolThreadGoal(jsonObject(result))};
    }
    if (!{null, 'user', 'automatic'}.contains(params['origin'])) throw const FormatException('Invalid goal mutation origin');
    final runtime = _goals[id] ?? (resident == null ? _makeGoalRuntime(id, config, loaded: false)
      : _loadedGoalRuntime(resident..config = config));
    final clearing = method == 'thread/goal/clear';
    final result = await runtime.call(clearing ? 'clear' : 'set', {...params, 'deferNotification': true}, cancellation: token);
    client.afterResponse[requestId] = () {
      if (_closing) return;
      if (!clearing || result['cleared'] == true) _broadcast(id, {'type': clearing ? 'goal.cleared' : 'goal.updated', 'data': {'goal': result['goal']}});
      if (!clearing) unawaited(_continueGoal(id));
    };
    return clearing ? <String, dynamic>{} : result;
  }
}
