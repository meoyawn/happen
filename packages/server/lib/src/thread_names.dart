part of '../server.dart';

String _threadNameUserText(Json item) {
  final content = (item['content'] as List).map(jsonObject).toList();
  final text = content.where((part) => part['type'] == 'text').map((part) => part['text']).join('\n');
  final attachments = content.where((part) => part['type'] != 'text')
    .map((part) => part['name'] as String? ?? (part['type'] == 'image' ? 'Attached image' : 'Attached file')).join(', ');
  return [text, if (attachments.isNotEmpty) 'Attachments: $attachments'].where((text) => text.trim().isNotEmpty).join('\n');
}

extension _ThreadNames on AgentServer {
  void _startThreadName(String id) {
    if (_closing || _tasks[id]?.sideParentID != null || _tasks[id]?.config?['ephemeral'] == true ||
        _titleRequests.containsKey(id)) {
      return;
    }
    final cancellation = CancellationToken();
    final generation = _generateThreadName(id, cancellation.merge(_threadLifetime(id).cancellation).merge(_lifetime));
    _titleRequests[id] = (cancellation: cancellation, done: generation);
    _requests.add(generation);
    unawaited(generation.catchError((Object error) {
      if (error is! CancelledException) traceError(error);
    }).whenComplete(() {
      _requests.remove(generation);
      if (identical(_titleRequests[id]?.done, generation)) _titleRequests.remove(id);
      cancellation.cancel();
    }));
  }

  Future<void> _releaseThreadName(String id) async {
    final pending = _titleRequests[id];
    if (pending == null) return;
    pending.cancellation.cancel();
    try { await pending.done; }
    on CancelledException { /* The title's provider effect has released its resources. */ }
    catch (error) { traceError(error); }
  }

  Future<void> _setThreadName(String id, String name, CancellationToken cancellation, {bool onlyIfUnnamed = false}) async {
    if (!onlyIfUnnamed) _titleRequests[id]?.cancellation.cancel();
    while (true) {
      cancellation.throwIfCancelled();
      final task = _tasks[id] ?? _Task(id, null);
      if (task.maintenance || task.finishing || task.busy && task.writer == null) {
        await (task.maintenance ? task.maintenanceDone!.future : task.finishing ? task.running! : task.ready!.future)
          .asCancellable(cancellation);
        continue;
      }
      final result = jsonObject(await _withWriter(task, (writer) => callIsolate(writer.port, 'thread.name.set',
        {'name': name, 'onlyIfUnnamed': onlyIfUnnamed}, cancellation: cancellation)));
      if (result['event'] case final Map<String, Object?> event) _broadcast(id, jsonObject(event));
      return;
    }
  }

  Future<void> _generateThreadName(String id, CancellationToken cancellation) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
    final work = cancellation.merge(deadline).merge(_lifetime);
    try {
      final snapshot = await _threadSnapshot(id, work, includeTurns: false);
      final thread = jsonObject(snapshot['thread']);
      if (thread['ephemeral'] == true) return;
      final name = thread['name'] as String?;
      if (name != null && name.trim().isNotEmpty) return;
      var source = thread['preview'] as String? ?? '';
      if (source.trim().isEmpty) {
        for (final raw in snapshot['pending'] as List? ?? []) {
          final pending = jsonObject(raw);
          final prompt = pending['prompt'] as String? ?? '';
          final attachments = (pending['attachments'] as List? ?? []).map((attachment) => attachment['name']).whereType<String>().join(', ');
          source = [prompt, if (attachments.isNotEmpty) 'Attachments: $attachments'].where((text) => text.trim().isNotEmpty).join('\n');
          if (source.trim().isNotEmpty) break;
        }
      }
      if (source.trim().isEmpty) {
        final history = await _readSession(_tasks[id] ?? _Task(id, null), 'thread/items/list',
          {'limit': 1, 'sortDirection': 'asc'}, work);
        final first = (history['data'] as List).firstOrNull;
        if (first != null && first['item']['type'] == 'userMessage') source = _threadNameUserText(jsonObject(first['item']));
      }
      if (source.trim().isEmpty) return;
      final config = jsonObject(snapshot['configuration']);
      final request = ModelRequest(taskId: newUuidV7(), model: requiredString(config, 'model'), instructions: '',
        modelInfo: config['model_info'] == null ? null : jsonObject(config['model_info']),
        input: [ConversationItem.text('user', source)], tools: const [], toolChoice: 'none',
        settings: jsonObject(config['provider_settings']), effectiveReasoning: config['provider_settings']['reasoning'] as String);
      final title = await _callNetwork('title.generate',
        {'provider': config['provider'], ...request.toJson()}, cancellation: work) as String;
      await _setThreadName(id, title, work, onlyIfUnnamed: true);
    } finally {
      deadline.cancel();
    }
  }
}
