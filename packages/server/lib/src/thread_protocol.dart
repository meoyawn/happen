part of '../server.dart';

class _RpcError implements Exception {
  const _RpcError(this.code, this.message);
  final int code;
  final String message;
}

extension _ThreadProtocol on AgentServer {
  Future<Json> _threadSnapshot(String id, _Client client, CancellationToken cancellation, {bool includeTurns = true}) async {
    var task = _tasks[id] ?? _Task(id, null);
    while (task.maintenance || task.finishing || task.busy && task.writer == null) {
      await (task.maintenance ? task.maintenanceDone!.future : task.finishing ? task.running! : task.ready!.future).asCancellable(cancellation);
      task = _tasks[id] ?? task;
    }
    var page = await _readSession(task, 'thread/read', {'includeTurns': includeTurns}, cancellation);
    if (page['needsProjection'] is String) {
      final source = _tasks[page['needsProjection']] ?? _Task(page['needsProjection'] as String, null);
      await _withWriter(source, (writer) => callIsolate(writer.port, 'session.prepare', {}, cancellation: cancellation));
      page = await _readSession(task, 'thread/read', {'includeTurns': includeTurns}, cancellation);
    }
    final thread = jsonObject(page['thread']);
    thread['status'] = _threadStatus(task);
    if (includeTurns) {
      final turns = (thread['turns'] as List).map(jsonObject).toList();
      if (task.liveTurn case final live?) {
        final index = turns.indexWhere((turn) => turn['id'] == live['id']);
        if (index >= 0) { turns[index] = {...turns[index], ...live, 'items': turns[index]['items']}; }
        else { turns.add({...live, 'items': <Json>[]}); }
      }
      for (final raw in task.liveItems.values) {
        final turnId = raw['turnId'];
        final turn = turns.where((turn) => turn['id'] == turnId).firstOrNull;
        if (turn == null) continue;
        final items = (turn['items'] as List).map(jsonObject).toList();
        if (!items.any((item) => item['id'] == raw['id'])) items.add({...raw}..remove('order')..remove('turnId'));
        turn['items'] = items;
      }
      thread['turns'] = turns;
    }
    return {...page, 'thread': thread, 'notificationThrough': task.notificationSeq,
      'liveTurn': task.liveTurn, 'liveItems': task.liveItems.values.toList(),
      'running': task.busy, 'questions': _questions.list(id), 'status': task.retryStatus};
  }

  Future<Object?> _threadRequest(String method, Json params, _Client client, Object requestID) async {
    final operation = CancellationToken();
    client.sessionReads[requestID] = operation;
    final cancellation = operation.merge(client.cancellation);
    try {
      if (method == 'thread/loaded/list') return {'data': _tasks.values.where((task) => task.loaded).map((task) => task.id).toList(), 'nextCursor': null};
      if (method == 'thread/list') {
        final page = await listThreads(directory, params, cancellation: cancellation);
        return {...page, 'data': [for (final raw in page['data'] as List) {
          ...jsonObject(raw), 'status': _threadStatus(_tasks[raw['id']]),
        }]};
      }
      if (method == 'thread/start') {
        if (params['historyMode'] != null && params['historyMode'] != 'paginated') throw const FormatException('Only paginated history is supported');
        final delay = _unloadDelay(params);
        final config = await _config(params), id = await _newTaskId(config, cancellation);
        final writer = await startStore(directory, id, inMemory: config['ephemeral'] == true);
        try { await callIsolate(writer.port, 'append_batch', {'events': [
          {'type': 'task.created', 'data': {...config, 'task_id': id}},
          if (config['developer_instructions'] case final String policy when policy.trim().isNotEmpty)
            {'type': 'instructions.updated', 'data': {'item': ConversationItem.text('developer', policy).toJson()}},
          ],
          'metadata': {'config': {...config, 'task_id': id}}}, cancellation: cancellation); }
        catch (_) { await writer.close(); rethrow; }
        _tasks[id] = _Task(id, config)..writer = writer..loaded = true..unloadDelaySecs = delay
          ..memoryStore = config['ephemeral'] == true ? writer : null;
        if (_goalsEnabled(config)) _loadedGoalRuntime(_tasks[id]!);
        _subscribe(client, id);
        if (params['dynamicTools'] != null) _clientTools.register(id, client.id, params['dynamicTools'], client.send);
        final page = await _threadSnapshot(id, client, cancellation, includeTurns: false);
        client.event({'method': 'thread/started', 'params': {'thread': page['thread']}});
        return {...page, 'model': config['model'], 'modelProvider': config['provider'], 'cwd': config['cwd'],
          'reasoningEffort': config['provider_settings']?['reasoning']};
      }
      final id = requiredString(params, 'threadId'); validateTaskId(id);
      if (method == 'thread/unsubscribe') {
        final subscribed = client.subscriptions.remove(id), task = _tasks[id];
        if (task?.loaded != true) return {'status': 'notLoaded'};
        if (subscribed) _scheduleUnload(task!);
        return {'status': subscribed ? 'unsubscribed' : 'notSubscribed'};
      }
      if (method == 'thread/resume' || method == 'turn/start' || method == 'turn/steer') _subscribe(client, id);
      var resident = _tasks[id];
      while (resident?.maintenance == true || resident?.backgroundMaintenance != null) {
        await (resident!.backgroundMaintenance?.future ?? resident.maintenanceDone!.future).asCancellable(cancellation);
        resident = _tasks[id];
      }
      if (resident?.sideParentID != null) {
        if (method == 'thread/name/set') throw StateError('Side conversations are ephemeral and cannot be renamed.');
        if (method.startsWith('thread/goal/')) throw StateError('ephemeral thread does not support goals');
        if ({'thread/fork', 'thread/archive', 'thread/unarchive', 'thread/resume'}.contains(method)) {
          throw StateError('Side conversations are ephemeral; close the side chat to discard it');
        }
      }
      if (method == 'thread/read' || method == 'thread/resume') {
        if (method == 'thread/resume') await _loadThread(id, cancellation, params: params);
        final snapshot = await _threadSnapshot(id, client, cancellation, includeTurns: method == 'thread/resume' ? params['excludeTurns'] != true : params['includeTurns'] == true);
        if (method == 'thread/resume') {
          final task = _tasks[id] ?? _Task(id, jsonObject(await _goalStore(id, 'metadata', {'key': 'config'}, cancellation)));
          if (_goalsEnabled(task.config!)) {
            final runtime = _loadedGoalRuntime(task);
            await runtime.call('resume', {}, cancellation: cancellation);
            final goal = await runtime.call('get_goal', {}, cancellation: cancellation);
            client.afterResponse[requestID] = () {
              _broadcast(id, {'type': goal['goal'] == null ? 'goal.cleared' : 'goal.updated', 'data': {'goal': goal['goal']}});
              unawaited(_continueGoal(id));
            };
          }
        }
        return snapshot;
      }
      if (const {'thread/goal/get', 'thread/goal/set', 'thread/goal/clear'}.contains(method)) {
        return await _threadGoalRequest(method, id, params, client, requestID, cancellation);
      }
      if (method == 'thread/items/list' || method == 'thread/turns/list') {
        await _threadSnapshot(id, client, cancellation, includeTurns: false);
        return await _readSession(_tasks[id] ?? _Task(id, null), method, params, cancellation);
      }
      if (method == 'thread/compact/start') {
        await _dispatchUntraced('task.compact', {'task_id': id}, client, requestID);
        return <String, dynamic>{};
      }
      if (method == 'thread/fork') {
        await _goals[id]?.call('prepare', {}, cancellation: cancellation);
        final task = _tasks[id] ?? _Task(id, null);
        final child = await _withWriter(task, (writer) async {
          final config = jsonObject(await callIsolate(writer.port, 'metadata', {'key': 'config'}, cancellation: cancellation));
          final child = await _newTaskId(config, cancellation);
          await callIsolate(writer.port, 'fork', {'id': child, 'lastTurnId': params['lastTurnId'], 'beforeTurnId': params['beforeTurnId']}, cancellation: cancellation);
          return child;
        }) as String;
        _subscribe(client, child);
        await _loadThread(child, cancellation);
        final page = await _threadSnapshot(child, client, cancellation, includeTurns: params['excludeTurns'] != true);
        client.event({'method': 'thread/started', 'params': {'thread': {...jsonObject(page['thread']), 'turns': <Json>[]}}});
        return page;
      }
      if (method == 'thread/archive' || method == 'thread/unarchive') {
        await _archive(_tasks[id] ?? _Task(id, null), method == 'thread/archive');
        if (method == 'thread/archive') return <String, dynamic>{};
        return await _threadSnapshot(id, client, cancellation, includeTurns: false);
      }
      if (method == 'turn/interrupt') {
        final task = _tasks[id];
        if (task?.busy == true && params['turnId'] != task?.protocolState['turnID']) throw const FormatException('Turn is no longer active');
        await _dispatchUntraced('task.cancel', {'task_id': id}, client, requestID);
        return <String, dynamic>{};
      }
      if (method == 'turn/start' || method == 'turn/steer') {
        final input = params['input'];
        if (input is! List) throw const FormatException('input must be an array');
        final task = _tasks[id];
        if (input.isEmpty) {
          if (task?.busy == true) throw const FormatException('Turn is already active');
          final snapshot = await _threadSnapshot(id, client, cancellation);
          final previous = (snapshot['thread']['turns'] as List).lastOrNull;
          if (previous?['status'] != 'failed' || previous?['id'] != params['expectedTurnId']) throw const FormatException('The failed turn is no longer available to retry');
          final turnId = newUuidV7();
          _begin(_tasks[id] ?? _Task(id, null), '', retry: true, settings: {'turnId': turnId});
          return {'turn': {'id': turnId, 'status': 'inProgress', 'items': <Json>[], 'error': null}};
        }
        if (method == 'turn/steer' && (task?.busy != true || params['expectedTurnId'] != task?.protocolState['turnID'])) throw const FormatException('Turn is no longer active');
        final prompt = input.where((item) => item['type'] == 'text').map((item) => item['text']).join('\n');
        final attachments = input.where((item) => item['type'] != 'text').map(jsonObject).toList();
        final turnId = newUuidV7();
        final reply = await _dispatchUntraced('task.send', {'task_id': id, 'prompt': prompt,
          'message_id': params['clientUserMessageId'] ?? newId(), 'turnId': turnId,
          'delivery': method == 'turn/steer' ? 'steer' : params['delivery'] ?? 'queue',
          if (params['cwd'] != null) 'cwd': params['cwd'],
          if (params['developerInstructions'] != null) 'instructions': params['developerInstructions'],
          if (attachments.isNotEmpty) 'attachments': attachments,
          if (params['effort'] != null) 'reasoning': params['effort']}, client, requestID);
        return method == 'turn/steer' ? {'turnId': task!.protocolState['turnID']} : {
          'turn': {'id': turnId, 'status': 'inProgress', 'items': <Json>[], 'error': null},
          'happen': reply,
        };
      }
      throw _RpcError(-32601, 'Method not found: $method');
    } finally { client.sessionReads.remove(requestID); operation.cancel(); }
  }
}
