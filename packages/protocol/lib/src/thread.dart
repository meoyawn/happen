import 'dart:convert';

import '../protocol.dart';

/// The state store keeps a private goal version and millisecond timestamps;
/// Codex's public ThreadGoal exposes seconds and camelCase status variants.
Json protocolThreadGoal(Json goal) => {
  'threadId': goal['threadId'], 'objective': goal['objective'],
  'status': switch (goal['status']) {'budget_limited' => 'budgetLimited', 'usage_limited' => 'usageLimited', final value => value},
  'tokenBudget': goal['tokenBudget'], 'tokensUsed': goal['tokensUsed'], 'timeUsedSeconds': goal['timeUsedSeconds'],
  'createdAt': (goal['createdAtMs'] as int) ~/ 1000, 'updatedAt': (goal['updatedAtMs'] as int) ~/ 1000,
};

/// Codex app-server v2 lifecycle. Only completed items enter durable history;
/// deltas and starts belong to the connection's live turn overlay.
List<Json> threadNotifications(String threadID, Json record, Json state) {
  final data = jsonObject(record['data'] ?? {}), result = <Json>[];
  final now = DateTime.tryParse(record['created_at'] as String? ?? '')?.millisecondsSinceEpoch ??
    DateTime.now().millisecondsSinceEpoch;
  final turn = state['turnID'] as String? ?? '$threadID:initial';
  void emit(String method, Json params) => result.add({'method': method, 'params': {
    'threadId': threadID, 'turnId': state['turnID'] ?? turn, ...params,
    'happen': {'createdAt': now, if (record['seq'] != null) 'sourceSeq': record['seq']},
  }});
  void item(Json item, {bool started = false}) => emit(started ? 'item/started' : 'item/completed', {'item': item});
  String assistant() => state['assistantID'] as String? ?? '$turn:assistant';
  Json? tool(String id, String name, Object? input, {String? parent}) {
    if (const {'exec_command', 'functions.exec_command', 'apply_patch', 'functions.apply_patch',
        'view_image', 'functions.view_image', 'clock.sleep', 'clock__sleep', 'image_gen.imagegen', 'image_gen__imagegen'}.contains(name)) {
      (state['nativeCalls'] ??= <String, dynamic>{})[id] = true;
      return null;
    }
    final calls = jsonObject(state['calls'] ?? {});
    final match = RegExp(r'^mcp__(.*?)__(.+)$').firstMatch(name);
    final pieces = name.split('.');
    final mcp = match != null || pieces.length > 1 && !{'functions', 'tools'}.contains(pieces.first);
    final value = <String, dynamic>{
      'id': id, 'type': mcp ? 'mcpToolCall' : 'dynamicToolCall', 'status': 'inProgress',
      if (mcp) ...{'server': match?[1] ?? pieces.first, 'tool': match?[2] ?? pieces.skip(1).join('.'), 'arguments': input}
      else ...{'namespace': pieces.length > 1 ? pieces.first : null, 'tool': pieces.last, 'arguments': input,
        'contentItems': null, 'success': null},
      'startedAtMs': now, if (parent != null) 'parentCallId': parent,
    };
    calls[id] = value;
    state['calls'] = calls;
    return value;
  }
  void output(Iterable<Object?> values, int ordinal) {
    for (final value in values) {
      final raw = jsonObject(value);
      for (final part in (raw['content'] as List? ?? []).map(jsonObject)) {
        final id = '${assistant()}:${ordinal++}';
        switch (part['type']) {
          case 'text':
            item({'id': id, 'type': 'agentMessage', 'text': part['text'] ?? '',
              'phase': (raw['content'] as List).any((p) => p['type'] == 'tool_call') ? 'commentary' : 'final_answer',
              'startedAtMs': state['modelStarted'] ?? now, 'completedAtMs': now});
          case 'reasoning':
            item({'id': id, 'type': 'reasoning', 'summary': [part['text'] ?? ''], 'content': <String>[],
              'startedAtMs': state['modelStarted'] ?? now, 'completedAtMs': now});
          case 'tool_call':
            final name = '${part['namespace'] == null ? '' : '${part['namespace']}.'}${part['name']}';
            final call = tool(part['id'] as String, name, part['input']);
            if (call != null) item(call, started: true);
        }
      }
    }
    state['ordinal'] = ordinal;
    state['completedOrdinal'] = ordinal;
    state.remove('streamType');
  }
  void nativeItem(Json data, {bool started = false}) {
    final value = jsonObject(data['item']), id = requiredString(value, 'id');
    final starts = jsonObject(state['nativeItemStarts'] ?? {});
    if (started) starts[id] = now;
    final start = started ? now : starts.remove(id);
    state['nativeItemStarts'] = starts;
    emit(started ? 'item/started' : 'item/completed', {'turnId': data['turnId'], 'item': {
      ...value, 'startedAtMs': start, if (!started) 'completedAtMs': data['completedAtMs'] ?? now,
    }});
  }
  for (final completion in (data['nativeCompletions'] as List? ?? []).map(jsonObject)) { nativeItem(completion); }
  switch (record['type']) {
    case 'native.item.started': nativeItem(data, started: true);
    case 'native.item.completed': nativeItem(data);
    case 'turn.started':
      state['turnID'] = data['turnId'] ?? data['id'] ?? record['id'] ?? newId();
      state['turnStarted'] = now;
      emit('turn/started', {'turn': {'id': state['turnID'], 'status': 'inProgress', 'items': <Json>[], 'startedAt': now ~/ 1000, 'error': null}});
    case 'input.pending': emit('happen/inbox/enqueued', {'input': data});
    case 'input.delivery': emit('happen/inbox/updated', data);
    case 'input.discarded': emit('happen/inbox/cancelled', data);
    case 'input.committed':
      final value = jsonObject(data['item']);
      if (value['role'] == 'user' && value['native']?['harness'] == null) {
        item({'id': value['id'], 'clientId': data['message_id'], 'type': 'userMessage',
          'content': [for (final part in value['content'] as List? ?? [])
            if (part['type'] == 'text') {'type': 'text', 'text': part['text'], 'text_elements': <Json>[]}
            else part], 'startedAtMs': now, 'completedAtMs': now});
        emit('happen/inbox/delivered', {'id': data['message_id']});
      }
    case 'model.started':
      state['assistantID'] = requiredString(data, 'assistantMessageID');
      state['modelStarted'] = now;
      state['ordinal'] = 0;
      state['completedOrdinal'] = 0;
      state.remove('streamType');
    case 'text.delta':
    case 'reasoning.delta':
      final type = record['type'] == 'text.delta' ? 'agentMessage' : 'reasoning';
      var ordinal = state['ordinal'] as int? ?? 0;
      if (state['streamType'] != null && state['streamType'] != type) ordinal++;
      final id = '${assistant()}:$ordinal';
      if (state['streamType'] != type) item({'id': id, 'type': type,
        if (type == 'agentMessage') 'text': '' else ...{'summary': <String>[], 'content': <String>[]},
        'startedAtMs': now}, started: true);
      state['ordinal'] = ordinal;
      state['streamType'] = type;
      emit(type == 'agentMessage' ? 'item/agentMessage/delta' : 'item/reasoning/summaryTextDelta', {
        'itemId': id, 'delta': record['delta'], if (type == 'reasoning') 'summaryIndex': 0,
      });
    case 'model.output':
      state['assistantID'] = data['assistantMessageID'] ?? state['assistantID'];
      output([data['item']], data['ordinal'] as int? ?? 0);
    case 'model.completed':
      state['assistantID'] = data['assistantMessageID'] ?? state['assistantID'];
      final committed = (data['committed_output_ids'] as List? ?? []).toSet();
      output((data['output'] as List? ?? []).where((item) => !committed.contains(item['id'])),
        data['ordinal'] as int? ?? 0);
      emit('thread/tokenUsage/updated', {'tokenUsage': data['usage'] ?? <String, Object?>{}});
    case 'tool.started':
      final id = requiredString(data, 'call_id');
      if (state['calls']?[id] == null) {
        final call = tool(id, '${data['namespace'] == null ? '' : '${data['namespace']}.'}${data['name']}', data['input']);
        if (call != null) item(call, started: true);
      }
    case 'host_tool.started':
      final call = tool(requiredString(data, 'id'), requiredString(data, 'name'), data['arguments'], parent: data['parent_call_id'] as String?);
      if (call != null) item(call, started: true);
    case 'host_tool.completed':
    case 'tool.completed':
      final parts = record['type'] == 'tool.completed' ? (data['item']?['content'] as List? ?? []) : [data];
      for (final part in parts) {
        final id = (part['call_id'] ?? part['id']) as String;
        if ((state['nativeCalls'] as Map?)?.remove(id) == true) continue;
        final previous = jsonObject((state['calls'] as Map?)?.remove(id) ??
          {'id': id, 'type': 'dynamicToolCall', 'tool': part['name'] ?? 'tool', 'arguments': null, 'startedAtMs': now});
        final failed = jsonObject(part).containsKey('error') || part['is_error'] == true;
        final value = part['error'] ?? part['output'];
        final content = <Object?>[
          if (value is Map && value['content'] is List) ...value['content'] as List
          else if (part['native']?['gpt']?['content_items'] == true && value is String) ...jsonDecode(value) as List
          else {'type': 'text', 'text': value is String ? value : jsonEncode(value)},
          if (part['native']?['gpt']?['inline_images'] != true) ...part['images'] as List? ?? [],
        ];
        item({...previous, 'status': part['cancelled'] == true ? 'interrupted' : failed ? 'failed' : 'completed',
          'completedAtMs': now, 'durationMs': now - (previous['startedAtMs'] as int? ?? now),
          if (previous['type'] == 'dynamicToolCall') ...{
            'contentItems': [for (final raw in content) switch (jsonObject(raw)) {
              {'type': 'input_image', 'image_url': final String url} => {'type': 'inputImage', 'imageUrl': url},
              {'type': 'image', 'data': final String data, 'mime_type': final String mime} =>
                {'type': 'inputImage', 'imageUrl': 'data:$mime;base64,$data'},
              {'type': 'input_audio', 'audio_url': final String url} => {'type': 'inputAudio', 'audioUrl': url},
              {'text': final String text} => {'type': 'inputText', 'text': text},
              final value => {'type': 'inputText', 'text': jsonEncode(value)},
            }], 'success': !failed && part['cancelled'] != true,
          } else ...{'result': {'content': content}, if (failed) 'error': {'message': value.toString()}}});
      }
    case 'compaction.started':
      state['compactionID'] = '${state['turnID'] ?? turn}:compaction';
      item({'id': state['compactionID'], 'type': 'contextCompaction', 'summary': '', 'status': 'inProgress', 'startedAtMs': now}, started: true);
    case 'context.compacted':
    case 'compaction.cancelled':
      item({'id': state.remove('compactionID') ?? '$turn:compaction', 'type': 'contextCompaction',
        'summary': data['summary'] ?? '', 'status': record['type'] == 'context.compacted' ? 'completed' : 'interrupted', 'completedAtMs': now});
    case 'model.retrying':
      state['ordinal'] = state['completedOrdinal'] ?? 0;
      state.remove('streamType');
      emit('happen/turn/retrying', {...record}..remove('notifications'));
    case 'configuration.updated': emit('happen/thread/configuration', data);
    case 'goal.updated': emit('thread/goal/updated', {'goal': data['goal']});
    case 'goal.cleared': emit('thread/goal/cleared', {});
    case 'task.archived': emit('thread/archived', {});
    case 'task.unarchived': emit('thread/unarchived', {});
    case 'thread.name.updated': emit('thread/name/updated', {'threadName': data['name']});
    case 'question.asked': emit('happen/question/asked', data);
    case 'question.replied': emit('happen/question/replied', data);
    case 'question.rejected': emit('happen/question/rejected', data);
    case 'side.closed': emit('happen/side/closed', data);
    case 'turn.completed':
    case 'turn.failed':
    case 'turn.cancelled':
      if (data['incompleteUsage']?['usage'] case final Map<String, Object?> usage) {
        emit('thread/tokenUsage/updated', {'tokenUsage': usage});
      }
      emit('turn/completed', {'turn': {'id': state['turnID'] ?? turn, 'items': <Json>[],
        'status': record['type'] == 'turn.failed' ? 'failed' : record['type'] == 'turn.cancelled' ? 'interrupted' : 'completed',
        'error': record['type'] == 'turn.failed' ? {'message': data['error'].toString()} : null,
        'startedAt': (state['turnStarted'] as int? ?? now) ~/ 1000, 'completedAt': now ~/ 1000}});
  }
  return result;
}

/// T3Code's item-addressed reconciliation: completion replaces streamed text;
/// late deltas never resurrect completed items or append duplicate final text.
void applyThreadNotification(Map<String, Json> items, Json notification) {
  final params = jsonObject(notification['params'] ?? {}), method = notification['method'];
  if (method == 'item/started' || method == 'item/completed') {
    final value = jsonObject(params['item']), id = requiredString(value, 'id');
    if (method == 'item/started' && items[id]?['completedAtMs'] != null) return;
    items[id] = {...value, 'turnId': params['turnId'], 'live': method == 'item/started',
      'order': items[id]?['order'] ?? items.length};
  } else if (method == 'item/agentMessage/delta' || method == 'item/reasoning/summaryTextDelta') {
    final id = requiredString(params, 'itemId'), previous = items[id];
    if (previous == null || previous['live'] != true) return;
    if (method == 'item/agentMessage/delta') {
      items[id] = {...previous, 'text': '${previous['text'] ?? ''}${params['delta']}'};
    } else {
      final summary = List<String>.from(previous['summary'] as List? ?? []);
      final index = params['summaryIndex'] as int? ?? 0;
      if (index < 0 || index > 1000) throw const FormatException('Invalid reasoning summary index');
      while (summary.length <= index) { summary.add(''); }
      summary[index] += params['delta'] as String;
      items[id] = {...previous, 'summary': summary};
    }
  } else if (method == 'turn/completed' || method == 'happen/turn/retrying') {
    for (final entry in items.entries.toList()) {
      if (entry.value['turnId'] != params['turnId'] || entry.value['live'] != true) continue;
      if (method == 'happen/turn/retrying' && {'agentMessage', 'reasoning'}.contains(entry.value['type'])) {
        items.remove(entry.key);
      } else if (method == 'turn/completed') {
        // Unified exec belongs to the loaded thread. A yielded CLI can finish
        // after its initiating turn; only its native exit watcher completes it.
        if (entry.value['type'] == 'commandExecution' && entry.value['status'] == 'inProgress') continue;
        items[entry.key] = {...entry.value, 'live': false, 'status': 'interrupted'};
      }
    }
  }
}
