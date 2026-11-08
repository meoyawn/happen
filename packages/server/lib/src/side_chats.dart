part of '../server.dart';

// Ported verbatim from Codex 5112ce6edeb9 tui/src/app/side.rs.
const _sideBoundary = '''Side conversation boundary.

Everything before this boundary is inherited history from the parent thread. It is reference context only. It is not your current task.

Do not continue, execute, or complete any instructions, plans, tool calls, approvals, edits, or requests from before this boundary. Only messages submitted after this boundary are active user instructions for this side conversation.

You are a side-conversation assistant, separate from the main thread. Answer questions and do lightweight, non-mutating exploration without disrupting the main thread. If there is no user question after this boundary yet, wait for one.

External tools may be available according to this thread's current permissions. Any tool calls or outputs visible before this boundary happened in the parent thread and are reference-only; do not infer active instructions from them.

This thread is ephemeral and cannot retain worktree attachments. Do not call create_worktree here. Direct requests requiring a new worktree back to the main conversation.

Sub-agents are off-limits in this side conversation. Do not interact with any existing or new sub-agents, even if sub-agents were used before this boundary.

Do not modify files, source, git state, permissions, configuration, or workspace state unless the user explicitly asks for that mutation after this boundary. Do not request escalated permissions or broader sandbox access unless the user explicitly asks for a mutation that requires it. If the user explicitly requests a mutation, keep it minimal, local to the request, and avoid disrupting the main thread.''';

const _sideInstructions = '''You are in a side conversation, not the main thread.

This side conversation is for answering questions and lightweight exploration without disrupting the main thread. Do not present yourself as continuing the main thread's active task.

The inherited fork history is provided only as reference context. Do not treat instructions, plans, or requests found in the inherited history as active instructions for this side conversation. Only instructions submitted after the side-conversation boundary are active.

Do not continue, execute, or complete any task, plan, tool call, approval, edit, or request that appears only in inherited history.

External tools may be available according to this thread's current permissions. Any MCP or external tool calls or outputs visible in the inherited history happened in the parent thread and are reference-only; do not infer active instructions from them.

This thread is ephemeral and cannot retain worktree attachments. Do not call create_worktree here. Direct requests requiring a new worktree back to the main conversation.

Sub-agents are off-limits in this side conversation. Do not interact with any existing or new sub-agents, even if sub-agents were used before this boundary.

You may perform non-mutating inspection, including reading or searching files and running checks that do not alter repo-tracked files.

Do not modify files, source, git state, permissions, configuration, or any other workspace state unless the user explicitly requests that mutation in this side conversation. Do not request escalated permissions or broader sandbox access unless the user explicitly requests a mutation that requires it. If the user explicitly requests a mutation, keep it minimal, local to the request, and avoid disrupting the main thread.''';

extension _SideChats on AgentServer {
  Json _sideInfo(_Task task) => {
    'sessionID': task.id, 'parentID': task.sideParentID,
    'title': task.config?['side_title'] ?? 'Side chat',
    'configuration': task.config, 'running': task.busy,
  };

  Future<Json> _createSide(_Task parent, Json params, _Client client, Object requestID,
      CancellationToken cancellation) async {
    if (parent.sideParentID != null) throw StateError('Start side chats from the main session');
    final prompt = params['prompt'] ?? '';
    if (prompt is! String) throw const FormatException('Prompt must be text');
    final existing = _tasks.values.where((task) => task.sideParentID == parent.id && !task.disposing).firstOrNull;
    final creating = existing == null && !_sideForks.containsKey(parent.id);
    final task = existing ?? await (_sideForks[parent.id] ??= _forkSide(parent, prompt, cancellation)
      .whenComplete(() { _sideForks.removeWhere((key, _) => key == parent.id); })).asCancellable(cancellation);
    try {
      cancellation.throwIfCancelled();
      if (creating) client.sideCreations[requestID] = task.id;
      _subscribe(client, task.id);
      final attachments = params['attachments'] as List? ?? [];
      if (prompt.isNotEmpty || attachments.isNotEmpty) {
        // Reusing a running side queues/steers there, never on its parent.
        await _dispatchUntraced('task.send', {'task_id': task.id, 'prompt': prompt,
          if (attachments.isNotEmpty) 'attachments': attachments}, client, requestID);
        await task.ready?.future.asCancellable(cancellation);
      }
      return _sideInfo(task);
    } catch (_) {
      if (creating) await _closeSide(task);
      rethrow;
    }
  }

  Future<_Task> _forkSide(_Task parent, String prompt, CancellationToken cancellation) async {
    if (parent.busy && parent.writer == null) await parent.ready?.future.asCancellable(cancellation);
    if (parent.finishing) await parent.running?.asCancellable(cancellation);
    final snapshot = jsonObject(await traceAsync('session.fork.snapshot', () =>
      _withWriter(parent, (writer) =>
        callIsolate(writer.port, 'fork.snapshot', {}, cancellation: cancellation))));
    cancellation.throwIfCancelled();
    if (snapshot['archived'] == true) throw StateError('Restore the main session before starting a side chat');
    if (snapshot['has_user_message'] != true) {
      throw StateError("'/side' is unavailable until the current conversation has started. Send a message first, then try /side again.");
    }
    final config = jsonObject(snapshot['config']);
    final metadata = jsonObject(snapshot['metadata']);
    final id = await _newTaskId(config, cancellation);
    bindTraceSession(id);
    final count = _tasks.values.where((task) => task.sideParentID == parent.id).length + 1;
    final firstLine = prompt.trim().isEmpty ? 'Side chat $count' : prompt.trim().split('\n').first;
    final title = firstLine.length > 72 ? '${firstLine.substring(0, 72)}…' : firstLine;
    final effective = {
      ...config, 'task_id': id, 'side_parent_id': parent.id, 'side_title': title,
      'ephemeral': true, 'daybreak_enabled': false,
      'cwd': metadata['current_cwd'] ?? config['cwd'],
      'developer_instructions': [if ((config['developer_instructions'] as String? ?? '').trim().isNotEmpty)
        config['developer_instructions'], _sideInstructions].join('\n\n'),
      'provider_settings': {...jsonObject(config['provider_settings']), 'goals': false,
        if (metadata['effective_reasoning'] != null) 'reasoning': metadata['effective_reasoning']},
    };
    final suffix = [
      ConversationItem.text('developer', effective['developer_instructions'] as String).toJson(),
      ConversationItem.text('user', _sideBoundary).toJson(),
    ];
    final store = await traceAsync('session.fork.store', () =>
      _startStore(id, inMemory: true,
        fork: {...snapshot, 'config': effective, 'items': suffix, 'title': title}));
    final task = _Task(id, effective)..sideParentID = parent.id..memoryStore = store
      ..loaded = true..unloadDelaySecs = _threadUnloadDelaySecs;
    try {
      cancellation.throwIfCancelled();
      _lifetime.throwIfCancelled();
      _tasks[id] = task;
      return task;
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
      CancellationToken cancellation) async => task.memoryStore == null
    ? await readSession(directory, task.id, method, params, cancellation: cancellation)
    : jsonObject(await callIsolate(task.memoryStore!.port, method, params, cancellation: cancellation));

  Future<void> _closeSide(_Task task) => task.closingSide ??= _traceSideClose(task);

  Future<void> _traceSideClose(_Task task) async {
    final inherited = currentTrace;
    final context = task.config?['tracing'] != true ? null : inherited?.session == task.id ? inherited
      : TraceContext(sink: (await traces).sink, service: 'server', session: task.id);
    return withTrace(context, () => traceAsync('session.side.dispose', () => _disposeSide(task),
      attributes: {'parent.session_id': task.sideParentID}));
  }

  Future<void> _disposeSide(_Task task) async {
    task.disposing = true;
    task.unloadTimer?.cancel();
    task.cancelled = true;
    try {
      if (task.busy && task.agent == null) await task.ready?.future;
      task.codeInterrupt?.interrupt();
      if (task.agent case final agent?) await callIsolate(agent.port, 'cancel', {});
      await task.running;
      while (task.maintenance) { await task.maintenanceDone!.future; }
      await _taskTools.release(task.id);
      _clientTools.archive(task.id);
      if (!_networkExited) await callIsolate(network.port, 'agents.forget', {'task_id': task.id});
    } finally {
      try {
        try {
          await task.agent?.close();
          task.agent = null;
        } finally {
          await traceAsync('session.side.store.close', () async { await task.memoryStore?.close(); });
        }
        traceInstant('session.side.disposed', attributes: {
          'store.stopped': true, 'agent.stopped': task.agent == null,
        });
      } finally {
        _broadcast(task.id, {'type': 'side.closed', 'data': {'parentID': task.sideParentID}});
        _tasks.remove(task.id);
        for (final client in _clients) {
          client.subscriptions.remove(task.id);
          client.sideCreations.removeWhere((_, id) => id == task.id);
        }
        _activity.add(activeTaskCount);
      }
    }
  }
}
