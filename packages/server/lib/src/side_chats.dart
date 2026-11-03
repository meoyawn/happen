part of '../server.dart';

const _sideInstructions = '''
You are in an ephemeral side conversation, separate from the main session.
Everything before the side conversation boundary is inherited reference context,
not your current task. Only user messages after the boundary are active instructions.
Do not continue or execute inherited requests, plans, approvals, or tool calls.
Answer questions and do lightweight exploration without disrupting the main session.
Do not modify files, git state, configuration, permissions, or workspace state unless
the user explicitly requests that mutation in this side conversation.
Do not interact with existing or new sub-agents or create worktrees.
Tools and outputs inherited from the parent are reference material only.
''';

extension _SideChats on AgentServer {
  Json _sideInfo(_Task task) => {
    'sessionID': task.id, 'parentID': task.sideParentID,
    'title': task.config?['side_title'] ?? 'Side chat',
    'configuration': task.config, 'running': task.busy,
  };

  Future<Json> _createSide(_Task parent, Json params, _Client client,
      CancellationToken cancellation) async {
    if (parent.sideParentID != null) throw StateError('Start side chats from the main session');
    final prompt = params['prompt'] ?? '';
    if (prompt is! String) throw const FormatException('Prompt must be text');
    if (parent.busy && parent.writer == null) await parent.ready?.future.asCancellable(cancellation);
    if (parent.finishing) await parent.running?.asCancellable(cancellation);
    final snapshot = jsonObject(await traceAsync('session.fork.snapshot', () =>
      _withWriter(parent, (writer) =>
        callIsolate(writer.port, 'fork.snapshot', {}, cancellation: cancellation))));
    cancellation.throwIfCancelled();
    if (snapshot['archived'] == true) throw StateError('Restore the main session before starting a side chat');
    final config = jsonObject(snapshot['config']);
    final metadata = jsonObject(snapshot['metadata']);
    final id = await _newTaskId(config, cancellation);
    bindTraceSession(id);
    final count = _tasks.values.where((task) => task.sideParentID == parent.id).length + 1;
    final firstLine = prompt.trim().isEmpty ? 'Side chat $count' : prompt.trim().split('\n').first;
    final title = firstLine.length > 72 ? '${firstLine.substring(0, 72)}…' : firstLine;
    final effective = {
      ...config, 'task_id': id, 'side_parent_id': parent.id, 'side_title': title,
      'cwd': metadata['current_cwd'] ?? config['cwd'],
      'instructions': '${config['instructions']}\n\n$_sideInstructions',
      'provider_settings': {...jsonObject(config['provider_settings']), 'goals': false,
        if (metadata['effective_reasoning'] != null) 'reasoning': metadata['effective_reasoning']},
    };
    final input = (snapshot['input'] as List).map((item) => ConversationItem.fromJson(jsonObject(item))).toList();
    final completed = input.expand((item) => item.content)
      .where((part) => part['type'] == 'tool_result').map((part) => part['call_id']).toSet();
    // A running parent's last committed model output may contain tool calls.
    // Settle their copied records without executing or cancelling the originals.
    final inherited = [
      ...input.map((item) => item.toJson()),
      for (final call in input.expand((item) => item.calls))
        if (!completed.contains(call.id)) ConversationItem.toolResult(call,
          'This call belongs to the parent session. Its result was not available at the side conversation boundary.',
          isError: true).toJson(),
      ConversationItem.text('user',
        'Side conversation boundary. All preceding history is reference context only. '
        'Do not continue any previous task. Only subsequent user messages are active instructions.').toJson(),
    ];
    final store = await traceAsync('session.fork.store', () =>
      startStore(directory, id, inMemory: true,
        fork: {...snapshot, 'config': effective, 'input': inherited, 'title': title}));
    final task = _Task(id, effective)..sideParentID = parent.id..sideStore = store;
    try {
      cancellation.throwIfCancelled();
      _lifetime.throwIfCancelled();
      _tasks[id] = task;
      client.subscriptions.add(id);
      client.sessionSubscriptions.add(id);
      final attachments = params['attachments'] as List? ?? [];
      if (prompt.isNotEmpty || attachments.isNotEmpty) {
        _begin(task, prompt, settings: {'sent_at': DateTime.now().toUtc().toIso8601String(),
          if (attachments.isNotEmpty) 'attachments': attachments});
        await task.ready!.future.asCancellable(cancellation);
      }
      return _sideInfo(task);
    } catch (_) {
      if (_tasks[id] == task) {
        await _closeSide(task);
      } else {
        await store.close();
      }
      rethrow;
    }
  }

  Future<Json> _readSession(_Task task, String method, Json params,
      CancellationToken cancellation) async => task.sideParentID == null
    ? await readSession(directory, task.id, method, params, cancellation: cancellation)
    : jsonObject(await callIsolate(task.sideStore!.port, method, params, cancellation: cancellation));

  Future<void> _closeSide(_Task task) =>
    task.closingSide ??= _disposeSide(task);

  Future<void> _disposeSide(_Task task) async {
    task.disposing = true;
    task.cancelled = true;
    if (task.busy && task.agent == null) await task.ready?.future;
    task.codeInterrupt?.interrupt();
    if (task.agent case final agent?) await callIsolate(agent.port, 'cancel', {});
    await task.running;
    while (task.maintenance) { await task.maintenanceDone!.future; }
    try {
      await _taskTools.release(task.id);
      _clientTools.archive(task.id);
      if (!_networkExited) await callIsolate(network.port, 'agents.forget', {'task_id': task.id});
    } finally {
      await task.sideStore?.close();
      _broadcast(task.id, {'type': 'side.closed', 'data': {'parentID': task.sideParentID}});
      _tasks.remove(task.id);
      for (final client in _clients) {
        client.subscriptions.remove(task.id);
        client.sessionSubscriptions.remove(task.id);
      }
      _activity.add(activeTaskCount);
    }
  }
}
