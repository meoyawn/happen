part of '../server.dart';

// Codex ddd1812a51f4 thread_processor.rs::thread_fork_inner, adapted to Happen's
// configuration and reference-backed SQLite history.
extension _ThreadFork on AgentServer {
  Json _forkSource(Json params) {
    final path = params['path'];
    if (path == null || path == '') return params;
    if (path is! String) throw const FormatException('path must be a string');
    final source = File(path).resolveSymbolicLinksSync();
    final tasks = Directory('$directory/tasks').resolveSymbolicLinksSync();
    if (!p.isWithin(tasks, source) || p.basename(source) != 'history.sqlite' ||
        p.dirname(p.dirname(source)) != tasks) {
      throw const FormatException('Fork path must identify a stored thread');
    }
    return {...params, 'threadId': p.basename(p.dirname(source))};
  }

  Future<Json> _forkConfiguration(Json source, String? reasoning, Json params, CancellationToken cancellation) async {
    final provider = params['modelProvider'] ?? params['provider'] ?? source['provider'];
    final settings = jsonObject(params['settings'] ?? {});
    final changedProvider = provider != source['provider'];
    final configured = await _config({
      'provider': provider, 'model': params['model'] ?? (changedProvider ? null : source['model']),
      'cwd': params['cwd'] ?? source['cwd'],
      'settings': {if (!changedProvider) ...jsonObject(source['provider_settings']), ...settings},
      'reasoning': ?(params['reasoning'] ?? (changedProvider ? null : reasoning)),
      'developerInstructions': params['developerInstructions'] ?? source['developer_instructions'],
      'ephemeral': params['ephemeral'] == true, 'tracing': source['tracing'] == true,
      'threadSource': params['threadSource'] ?? source['thread_source'],
    }, cancellation: cancellation);
    return {...source, ...configured,
      if (params['baseInstructions'] is String) 'instructions': params['baseInstructions']
      else if (!changedProvider && params['model'] == null && source['instructions'] is String) 'instructions': source['instructions'],
    }..remove('task_id')..remove('history_base')..remove('forked_from_id');
  }

  Future<Json> _forkThread(String id, Json params, _Client client, Object requestID, CancellationToken cancellation) async {
    if (params['lastTurnId'] != null && params['beforeTurnId'] != null) {
      throw const FormatException('`beforeTurnId` cannot be combined with `lastTurnId`');
    }
    for (final key in ['lastTurnId', 'beforeTurnId']) {
      if (params[key] != null && (params[key] is! String || (params[key] as String).isEmpty)) {
        throw FormatException('$key must be a non-empty string');
      }
    }
    final ephemeral = params['ephemeral'] == true, includeTurns = params['excludeTurns'] != true;
    if (ephemeral && params['deferGoalContinuation'] == true) {
      throw const FormatException('`deferGoalContinuation` cannot be combined with `ephemeral`');
    }
    if (ephemeral && includeTurns) throw const FormatException('ephemeral paginated thread/fork requires `excludeTurns: true`');
    final delay = _unloadDelay(params);
    await _goals[id]?.call('prepare', {}, cancellation: cancellation);
    final source = await _threadSnapshot(id, cancellation, includeTurns: false);
    if (source['thread']['ephemeral'] == true) throw const FormatException('Fork requires a persisted source thread');
    final config = await _forkConfiguration(jsonObject(source['configuration']), source['reasoning'] as String?, params, cancellation);
    final child = await _newTaskId(config, cancellation);
    bindTraceSession(child);
    final task = _tasks[id] ?? _Task(id, null);
    if (ephemeral) {
      final snapshot = jsonObject(await _withWriter(task, (writer) => callIsolate(writer.port, 'fork.snapshot',
        {'lastTurnId': params['lastTurnId'], 'beforeTurnId': params['beforeTurnId']}, cancellation: cancellation)));
      final effective = {...config, 'forked_from_id': id};
      final writer = await startStore(directory, child, inMemory: true, fork: {
        ...snapshot, 'config': effective,
        'metadata': {...jsonObject(snapshot['metadata']), if (params['cwd'] != null) 'current_cwd': config['cwd']},
        if (config['developer_instructions'] != source['configuration']['developer_instructions'])
          'items': [ConversationItem.text('developer', config['developer_instructions'] as String).toJson()],
      });
      _tasks[child] = _Task(child, effective)..writer = writer..memoryStore = writer..loaded = true..unloadDelaySecs = delay;
    } else {
      await _withWriter(task, (writer) => callIsolate(writer.port, 'fork', {
        'id': child, 'lastTurnId': params['lastTurnId'], 'beforeTurnId': params['beforeTurnId'], 'configuration': config,
      }, cancellation: cancellation));
    }
    try {
      _subscribe(client, child);
      final fork = await _loadThread(child, cancellation, params: params, notifyStatus: false);
      final page = await _threadSnapshot(child, cancellation, includeTurns: includeTurns);
      final usage = includeTurns ? await callIsolate(fork.writer!.port, 'session.usage', {}, cancellation: cancellation) as Json? : null;
      final usageTurnId = usage?['turnId'] ?? (page['thread']['turns'] as List).lastOrNull?['id'];
      client.afterResponse[requestID] = () {
        if (usage != null && (page['thread']['turns'] as List).any((turn) => turn['id'] == usageTurnId)) {
          client.event({'method': 'thread/tokenUsage/updated', 'params': {'threadId': child, ...usage, 'turnId': usageTurnId}});
        }
        final started = {'method': 'thread/started', 'params': {'thread': {...jsonObject(page['thread']), 'turns': <Json>[]}}};
        for (final connection in _clients) { connection.event(started); }
      };
      return {...page, 'model': config['model'], 'modelProvider': config['provider'], 'cwd': config['cwd'],
        'reasoningEffort': config['provider_settings']?['reasoning']};
    } catch (_) {
      if (ephemeral) {
        final fork = _tasks.remove(child);
        client.subscriptions.remove(child);
        await fork?.writer?.close();
      }
      rethrow;
    }
  }
}
