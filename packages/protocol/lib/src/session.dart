import 'dart:convert';

import '../protocol.dart';

// Ported from OpenCode's schema/session-message.ts, session-event.ts and
// token-usage.ts. These JSON records are shared by SQLite, WebSocket and Flutter.
String sessionMessageID(String eventID) => 'msg_${eventID.replaceFirst(RegExp(r'^evt_'), '')}';

Json? lastAssistantWithUsage(Iterable<Json> messages) {
  final ordered = messages.toList()..sort((a, b) =>
    (a['metadata']?['seq'] as int? ?? 0).compareTo(b['metadata']?['seq'] as int? ?? 0));
  Json? result;
  for (final message in ordered) {
    if (message['type'] == 'compaction' && message['status'] == 'completed') result = null;
    if (message['type'] == 'assistant' && message['tokens'] is Map) result = message;
  }
  return result;
}

Json sessionTokens(Json usage) {
  final read = usage['cached_input_tokens'] as num? ?? 0;
  final write = usage['cache_write_tokens'] as num? ?? 0;
  final reasoning = usage['reasoning_tokens'] as num? ?? 0;
  return {
    'input': ((usage['input_tokens'] as num? ?? 0) - read - write).clamp(0, double.maxFinite),
    'output': ((usage['output_tokens'] as num? ?? 0) - reasoning).clamp(0, double.maxFinite),
    'reasoning': reasoning, 'cache': {'read': read, 'write': write},
  };
}

num sessionTokenTotal(Json tokens) => (tokens['input'] as num? ?? 0) +
  (tokens['output'] as num? ?? 0) + (tokens['reasoning'] as num? ?? 0) +
  (tokens['cache']?['read'] as num? ?? 0) + (tokens['cache']?['write'] as num? ?? 0);

/// Convert execution facts at their persistence boundary. New code outside the
/// execution engine consumes the OpenCode event contract exclusively.
List<Json> sessionEvents(String sessionID, Json record, Json state) {
  final result = <Json>[];
  final data = jsonObject(record['data'] ?? {});
  final created = DateTime.tryParse(record['created_at'] as String? ?? '')?.millisecondsSinceEpoch ??
    DateTime.now().millisecondsSinceEpoch;
  final sourceID = record['id'] as String? ?? (record['seq'] == null ? newId() : '$sessionID:${record['seq']}');
  final durable = record['seq'] != null;
  final config = jsonObject(state['config'] ?? {});
  Json model() => {'providerID': config['provider'] ?? 'openai', 'id': config['model'] ?? '',
    if (state['reasoning'] != null) 'variant': state['reasoning']};
  void add(String type, Json payload, {int version = 1, int? timestamp}) {
    final index = result.length;
    final sequence = (state['eventSeq'] as int? ?? 0) + 1;
    if (durable) state['eventSeq'] = sequence;
    result.add({
      'id': 'evt_$sourceID:$index', 'created': timestamp ?? created, 'type': type,
      'data': {'sessionID': sessionID, ...payload},
      if (durable) 'durable': {'aggregateID': sessionID, 'seq': sequence, 'version': version},
    });
  }
  void instructions(String text) {
    if (state['system'] == text) return;
    state['system'] = text;
    add('session.instructions.updated', {'text': text, 'delta': {}}, version: 2);
  }
  String assistant() => state['assistantMessageID'] as String? ??
    (state['assistantMessageID'] = 'msg_$sourceID');
  Json input(Object? raw) {
    if (raw is Map) return jsonObject(raw);
    if (raw is String) {
      try { final value = jsonDecode(raw); if (value is Map) return jsonObject(value); }
      on FormatException { /* Code-mode input is source text. */ }
    }
    return {'code': raw ?? ''};
  }
  String text(Json item) => (item['content'] as List? ?? []).where((part) => part['type'] == 'text')
    .map((part) => part['text']).join('\n');
  void synthetic(Json item, {String? description}) {
    if (text(item).isEmpty) return;
    add('session.synthetic', {'text': text(item), if (description != null) 'description': description,
      if (item['role'] != null) 'role': item['role'],
      if (item['native']?['harness']?['context'] != null) 'context': item['native']['harness']['context']});
  }
  void toolStart(String id, String name, Object? raw, {String? parent}) {
    final starting = state['assistantMessageID'] == null;
    final owner = assistant();
    if (starting) add('session.step.started', {'assistantMessageID': owner, 'agent': 'build', 'model': model(), 'started': created});
    final owners = jsonObject(state['toolMessages'] ?? {}); owners[id] = owner; state['toolMessages'] = owners;
    add('session.tool.input.started', {'assistantMessageID': owner, 'id': id, 'name': name});
    add('session.tool.called', {'assistantMessageID': owner, 'id': id, 'input': input(raw), 'executed': true,
      if (parent != null) 'native': {'parentCallID': parent}});
  }
  void toolEnd(String id, Object? output, {bool failed = false, List? images}) {
    final owner = state['toolMessages']?[id] as String? ?? assistant();
    final content = [
      {'type': 'text', 'text': output is String ? output : jsonEncode(output)},
      if (images != null) ...images,
    ];
    add(failed ? 'session.tool.failed' : 'session.tool.success', {
      'assistantMessageID': owner, 'id': id, 'content': content, 'executed': true,
      if (failed) 'error': {'type': 'unknown', 'message': output.toString()},
    }, version: 2);
  }
  switch (record['type']) {
    case 'input.pending':
      final inboxID = 'msg_${data['id']}';
      final pending = jsonObject(state['pending'] ?? {}); pending[inboxID] = true; state['pending'] = pending;
      add('session.inbox.enqueued', {'inboxID': inboxID, 'item': {
        'type': 'user', 'delivery': data['delivery'] ?? 'steer', 'text': data['prompt'] ?? '',
        'files': data['attachments'] ?? [],
        if (data['reasoning'] != null) 'metadata': {'reasoning': data['reasoning']},
      }}, timestamp: DateTime.tryParse(data['created_at'] as String? ?? '')?.millisecondsSinceEpoch);
    case 'input.discarded':
      for (final id in data['ids'] as List? ?? []) {
        add('session.inbox.cancelled', {'inboxID': 'msg_$id'});
        (state['pending'] as Map?)?.remove('msg_$id');
      }
    case 'task.created':
      state['config'] = data;
      state['tools'] = [];
      state['reasoning'] = data['provider_settings']?['reasoning'];
      add('session.created', {
        'projectID': data['project_id'] ?? data['cwd'] ?? sessionID,
        'location': {'directory': data['cwd'] ?? ''}, 'slug': sessionID, 'version': '1',
        'model': {'providerID': data['provider'] ?? 'openai', 'id': data['model'] ?? ''},
        'metadata': {'providerSettings': data['provider_settings'] ?? {}, 'reasoningUpdates': data['reasoning_updates'] == true},
      });
    case 'configuration.updated':
      state['reasoning'] = data['effort'] ?? data['item']?['settings']?['reasoning'];
      add('session.model.selected', {'model': model()});
    case 'instructions.updated':
    case 'environment.updated':
    case 'tools.updated':
    case 'agents.updated':
    case 'skills.updated':
    case 'mcp.updated':
    case 'client_tools.updated':
      final item = jsonObject(data['item'] ?? {});
      if (item['tools'] is List) {
        final tools = {for (final tool in (state['tools'] as List? ?? [])) '${tool['namespace']}.${tool['name']}': tool};
        for (final tool in item['tools']) { tools['${tool['namespace']}.${tool['name']}'] = tool; }
        state['tools'] = tools.values.toList();
      }
      synthetic(item, description: record['type'] as String);
    case 'input.committed':
      final item = jsonObject(data['item']);
      if (item['role'] == 'user' && item['native']?['harness'] == null) {
        final inboxID = 'msg_${data['message_id'] ?? sourceID}';
        if ((state['pending'] as Map?)?.remove(inboxID) == null) add('session.inbox.enqueued', {'inboxID': inboxID, 'item': {
          'type': 'user', 'delivery': data['delivery'] ?? 'steer',
          'text': text(item), 'files': [for (final part in item['content'] as List? ?? [])
            if (part['type'] == 'image' || part['type'] == 'file') part],
        }}, timestamp: DateTime.tryParse(data['sent_at'] as String? ?? '')?.millisecondsSinceEpoch);
        add('session.inbox.delivered', {'inboxID': inboxID});
      } else {
        synthetic(item);
      }
    case 'turn.started':
      state.remove('assistantMessageID');
      state['toolMessages'] = <String, dynamic>{};
      add('session.execution.started', {});
    case 'model.started':
      if (data['instructions'] case final String text) instructions(text);
      if (data['tools'] is List) {
        final tools = {for (final tool in (state['tools'] as List? ?? [])) '${tool['namespace']}.${tool['name']}': tool};
        for (final tool in data['tools']) { tools['${tool['namespace']}.${tool['name']}'] = tool; }
        state['tools'] = tools.values.toList();
      }
      state['assistantMessageID'] = requiredString(data, 'assistantMessageID');
      add('session.step.started', {'assistantMessageID': assistant(), 'agent': 'build', 'model': model(), 'started': created});
    case 'model.completed':
      state['assistantMessageID'] = requiredString(data, 'assistantMessageID');
      var ordinal = 0;
      for (final item in data['output'] as List? ?? []) {
        for (final part in item['content'] as List? ?? []) {
          if (part['type'] == 'text' || part['type'] == 'reasoning') {
            add('session.${part['type']}.ended', {'assistantMessageID': assistant(), 'ordinal': ordinal++,
              'text': part['text'] ?? '', if (part['native'] != null) 'native': part['native']});
          } else if (part['type'] == 'tool_call') {
            toolStart(part['id'] as String, '${part['namespace'] == null ? '' : '${part['namespace']}.'}${part['name']}', part['input']);
            ordinal++;
          }
        }
      }
      add('session.step.streamed', {'assistantMessageID': assistant()});
      add('session.step.ended', {'assistantMessageID': assistant(), 'finish':
        (data['output'] as List? ?? []).any((item) => (item['content'] as List? ?? []).any((part) => part['type'] == 'tool_call')) ? 'tool-calls' : 'stop',
        'tokens': sessionTokens(jsonObject(data['usage'] ?? {}))});
      state['lastAssistantMessageID'] = state['assistantMessageID'];
    case 'task.archived':
      add('session.archived', {});
    case 'task.unarchived':
      add('session.unarchived', {});
    case 'tool.started':
      final id = data['call_id'] as String;
      if (state['toolMessages']?[id] == null) toolStart(id,
        '${data['namespace'] == null ? '' : '${data['namespace']}.'}${data['name']}', data['input']);
    case 'host_tool.started':
      toolStart(data['id'] as String, data['name'] as String, data['arguments'], parent: data['parent_call_id'] as String?);
    case 'host_tool.completed':
      toolEnd(data['id'] as String, data['error'] ?? data['output'], failed: data.containsKey('error') || data['cancelled'] == true);
    case 'tool.completed':
      for (final part in data['item']?['content'] as List? ?? []) {
        toolEnd(part['call_id'] as String, part['output'], failed: part['is_error'] == true, images: part['images'] as List?);
      }
    case 'compaction.started':
      add('session.compaction.started', {'reason': data['reason'] == 'manual' ? 'manual' : 'auto'});
    case 'context.compacted':
      add('session.compaction.ended', {'reason': data['reason'] == 'manual' ? 'manual' : 'auto',
        'text': data['summary'] ?? '', 'model': model(), 'tokens': sessionTokens(jsonObject(data['usage'] ?? {}))});
    case 'turn.completed':
    case 'turn.failed':
    case 'turn.cancelled':
      add(switch (record['type']) {
        'turn.completed' => 'session.execution.succeeded',
        'turn.cancelled' => 'session.execution.interrupted',
        _ => 'session.execution.failed',
      }, {
        if (record['type'] == 'turn.cancelled') 'reason': 'user',
        if (record['type'] == 'turn.failed') 'error': {'type': 'unknown', 'message': data['error'].toString()},
      });
      state.remove('assistantMessageID');
  }
  return result;
}

/// OpenCode's projection is the same fold in the writer and in Flutter. Records
/// are replaced rather than mutated so identity-based UI caches stay valid.
List<Json> applySessionEvent(Map<String, Json> messages, Json event, Json state) {
  final data = jsonObject(event['data'] ?? {}), changed = <Json>[];
  final created = event['created'] as int? ?? 0;
  final sequence = event['durable']?['seq'] as int? ?? messages.values.fold<int>(0,
    (seq, message) => (message['metadata']?['seq'] as int? ?? 0) > seq ? message['metadata']['seq'] as int : seq) + 1;
  final messageID = sessionMessageID(event['id'] as String);
  void put(Json value) { messages[value['id'] as String] = value; changed.add(value); }
  Json base(String type, [String? id]) => {'id': id ?? messageID, 'type': type,
    'time': {'created': created}, 'metadata': {'seq': sequence}};
  Json? assistant() => messages[data['assistantMessageID']];
  void content(Json part, {String? toolID, int? ordinal}) {
    final message = assistant(); if (message == null) return;
    final parts = (message['content'] as List? ?? []).map(jsonObject).toList();
    final index = toolID == null ? ordinal! : parts.indexWhere((p) => p['type'] == 'tool' && p['id'] == toolID);
    if (index < 0 || index >= parts.length) { parts.add(part); } else { parts[index] = part; }
    put({...message, 'content': parts});
  }
  switch (event['type']) {
    case 'session.instructions.updated':
      if ((data['text'] as String? ?? '').isNotEmpty) put({...base('system'), 'text': data['text']});
    case 'session.synthetic':
      put({...base('synthetic'), 'text': data['text'],
        if (data['description'] != null) 'description': data['description'],
        if (data['role'] != null) 'role': data['role'],
        if (data['context'] != null) 'context': data['context']});
    case 'session.model.selected':
      put({...base('model-switched'), 'model': data['model']});
    case 'session.inbox.enqueued':
      state[data['inboxID'] as String] = {...jsonObject(data['item']), 'created': created, 'seq': sequence};
    case 'session.inbox.delivered':
      final item = state.remove(data['inboxID']) as Json?;
      if (item != null) put({...base('user', data['inboxID'] as String),
        'time': {'created': item['created']}, 'text': item['text'] ?? '', 'files': item['files'] ?? []});
      for (final previous in messages.values.toList()) {
        if (previous['type'] == 'assistant' && previous['time']?['streamed'] == null && previous['content'] is List &&
            (previous['content'] as List).isNotEmpty) put({...previous, 'content': <Json>[]});
      }
    case 'session.inbox.cancelled':
      state.remove(data['inboxID']);
    case 'session.step.started':
      for (final previous in messages.values.toList()) {
        if (previous['type'] == 'assistant' && previous['time']?['streamed'] == null && previous['content'] is List &&
            (previous['content'] as List).isNotEmpty) put({...previous, 'content': <Json>[]});
      }
      put({...base('assistant', data['assistantMessageID'] as String), 'agent': data['agent'], 'model': data['model'], 'content': <Json>[]});
    case 'session.text.ended':
    case 'session.reasoning.ended':
      content({'type': event['type'] == 'session.text.ended' ? 'text' : 'reasoning',
        'text': data['text'], if (data['native'] != null) 'native': data['native']}, ordinal: data['ordinal'] as int);
    case 'session.text.delta':
    case 'session.reasoning.delta':
      final message = assistant();
      if (message == null || message['time']?['streamed'] != null) break;
      final ordinal = data['ordinal'] as int;
      final parts = message['content'] as List;
      final previous = ordinal < parts.length ? parts[ordinal]['text'] as String? ?? '' : '';
      content({'type': event['type'] == 'session.text.delta' ? 'text' : 'reasoning',
        'text': previous + (data['delta'] as String)}, ordinal: ordinal);
    case 'session.status':
      final message = assistant();
      if (data['status']?['type'] == 'retry' && message != null && message['time']?['streamed'] == null) {
        put({...message, 'content': <Json>[]});
      }
    case 'session.step.streamed':
    case 'session.step.ended':
      final message = assistant();
      if (message != null) put({...message,
        if (data['tokens'] != null) 'tokens': data['tokens'],
        if (data['finish'] != null) 'finish': data['finish'],
        'time': {...jsonObject(message['time']), event['type'] == 'session.step.streamed' ? 'streamed' : 'completed': created}});
    case 'session.tool.input.started':
      content({'type': 'tool', 'id': data['id'], 'name': data['name'],
        'time': {'created': created}, 'state': {'status': 'streaming', 'input': ''}}, toolID: data['id'] as String);
    case 'session.tool.called':
    case 'session.tool.success':
    case 'session.tool.failed':
      final message = assistant();
      final tool = (message?['content'] as List? ?? []).where((p) => p['type'] == 'tool' && p['id'] == data['id']).firstOrNull;
      if (tool == null) break;
      final called = event['type'] == 'session.tool.called';
      content({...jsonObject(tool), 'executed': data['executed'],
        if (data['native'] != null) 'native': data['native'],
        'time': {...jsonObject(tool['time']), called ? 'ran' : 'completed': created},
        'state': {'status': called ? 'running' : event['type'] == 'session.tool.failed' ? 'error' : 'completed',
          'input': called ? data['input'] : tool['state']['input'],
          if (called) 'metadata': <String, dynamic>{},
          if (data['content'] != null) 'content': data['content'],
          if (data['error'] != null) 'error': data['error'],
        }}, toolID: data['id'] as String);
    case 'session.compaction.started':
      state['compactionID'] = messageID;
      put({...base('compaction'), 'status': 'running', 'reason': data['reason'], 'summary': ''});
    case 'session.compaction.ended':
      final id = state.remove('compactionID') as String? ?? messageID;
      put({...messages[id] ?? base('compaction', id), 'status': 'completed', 'reason': data['reason'],
        'time': {...jsonObject(messages[id]?['time'] ?? {'created': created}), 'completed': created},
        'summary': data['text'], if (data['tokens'] != null) 'tokens': data['tokens']});
    case 'session.execution.succeeded':
    case 'session.execution.interrupted':
    case 'session.execution.failed':
      final outcome = switch (event['type']) {'session.execution.succeeded' => 'succeeded',
        'session.execution.interrupted' => 'interrupted', _ => 'failed'};
      for (final message in messages.values.toList()) {
        if (message['type'] == 'compaction' && message['status'] == 'running') {
          put({...message, 'status': 'failed', 'outcome': outcome,
            'time': {...jsonObject(message['time']), 'completed': created},
            'error': data['error'] ?? {'message': 'Compaction interrupted'}});
        }
      }
      put({...base('idle'), 'outcome': outcome, if (data['error'] != null) 'error': data['error']});
  }
  return changed;
}
