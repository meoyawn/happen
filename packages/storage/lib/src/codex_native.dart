// Port of Codex rollout recorder and thread history materializer, f05aa41d.
// Rollout JSON shapes and byte/ordinal positions are retained in SQLite.
import 'dart:convert';
import 'dart:developer' show log;

import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

class CodexSqlite {
  CodexSqlite(this.db, this.threadID) {
    db.execute(r'''
      CREATE TABLE IF NOT EXISTS rollout_lines (
        ordinal INTEGER PRIMARY KEY,timestamp TEXT NOT NULL,line TEXT NOT NULL,
        byte_offset INTEGER NOT NULL,byte_length INTEGER NOT NULL,happen_context TEXT,happen_seq INTEGER
      ) STRICT;
      CREATE TABLE IF NOT EXISTS thread_turns (
        thread_id TEXT NOT NULL,turn_id TEXT NOT NULL,rollout_ordinal INTEGER NOT NULL,
        status TEXT NOT NULL,error_json TEXT,started_at INTEGER,completed_at INTEGER,duration_ms INTEGER,
        first_user_item_id TEXT,final_agent_item_id TEXT,rollout_byte_offset INTEGER,
        rollout_end_ordinal INTEGER,rollout_end_byte_offset INTEGER,root_turn_id TEXT,
        PRIMARY KEY(thread_id,turn_id)
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_thread_turns_page ON thread_turns(thread_id,rollout_ordinal);
      CREATE INDEX IF NOT EXISTS idx_thread_turns_end_page ON thread_turns(thread_id,rollout_end_ordinal,turn_id)
        WHERE rollout_end_ordinal IS NOT NULL;
      CREATE TABLE IF NOT EXISTS thread_items (
        thread_id TEXT NOT NULL,turn_id TEXT NOT NULL,item_id TEXT NOT NULL,rollout_ordinal INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL,item_json TEXT NOT NULL,item_type TEXT NOT NULL DEFAULT '',
        updated_at_ordinal INTEGER NOT NULL DEFAULT 0,started_at_ms INTEGER,completed_at_ms INTEGER,
        PRIMARY KEY(thread_id,turn_id,item_id)
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_thread_items_page ON thread_items(thread_id,rollout_ordinal);
      CREATE INDEX IF NOT EXISTS idx_thread_items_by_turn_page ON thread_items(thread_id,turn_id,rollout_ordinal);
      CREATE INDEX IF NOT EXISTS idx_thread_items_updated_page ON thread_items(thread_id,updated_at_ordinal);
      CREATE INDEX IF NOT EXISTS idx_thread_items_by_turn_updated_page ON thread_items(thread_id,turn_id,updated_at_ordinal);
      CREATE INDEX IF NOT EXISTS idx_thread_items_user_messages ON thread_items(thread_id,rollout_ordinal)
        WHERE item_type IS 'userMessage';
      CREATE TABLE IF NOT EXISTS thread_history_projection_state (
        thread_id TEXT PRIMARY KEY,next_rollout_byte_offset INTEGER NOT NULL,next_rollout_ordinal INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS thread_realtime_items (
        thread_id TEXT NOT NULL,item_id TEXT NOT NULL,rollout_ordinal INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL,item_type TEXT NOT NULL,item_json TEXT NOT NULL,
        PRIMARY KEY(thread_id,item_id)
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_thread_realtime_items_page ON thread_realtime_items(thread_id,rollout_ordinal);
      CREATE INDEX IF NOT EXISTS idx_thread_realtime_items_boundary ON thread_realtime_items(thread_id,rollout_ordinal)
        WHERE item_type IN ('realtime_session_started','realtime_session_closed');
      CREATE TRIGGER IF NOT EXISTS thread_realtime_items_projection_cleanup
        AFTER DELETE ON thread_history_projection_state BEGIN
          DELETE FROM thread_realtime_items WHERE thread_id IS OLD.thread_id;
        END;
    ''');
  }
  final TracedDatabase db;
  final String threadID;
  int get nextOrdinal => (db.select('SELECT max(ordinal) AS n FROM rollout_lines').single['n'] as int? ?? initialOrdinal - 1) + 1;
  int get initialOrdinal {
    if (db.select("SELECT 1 FROM sqlite_master WHERE name IS 'metadata'").isEmpty) return 0;
    final row = db.select("SELECT value FROM metadata WHERE key IS 'history_base'").firstOrNull;
    return row == null ? 0 : jsonDecode(row['value'] as String)?['end_ordinal_exclusive'] as int? ?? 0;
  }
  void append(List<Json> items, {String? timestamp}) {
    items = items.where(retainedCodexItem).toList();
    if (items.isEmpty) return;
    final ownsTransaction = db.raw.autocommit;
    db.execute(ownsTransaction ? 'BEGIN' : 'SAVEPOINT rollout_append');
    try {
      record(items, timestamp: timestamp); tryProject();
      db.execute(ownsTransaction ? 'COMMIT' : 'RELEASE rollout_append');
    } catch (_) {
      db.execute(ownsTransaction ? 'ROLLBACK' : 'ROLLBACK TO rollout_append');
      if (!ownsTransaction) db.execute('RELEASE rollout_append');
      rethrow;
    }
  }
  void record(List<Json> items, {String? timestamp}) {
    final last = db.select('SELECT ordinal,byte_offset,byte_length FROM rollout_lines ORDER BY ordinal DESC LIMIT 1').firstOrNull;
    var ordinal = (last?['ordinal'] as int? ?? initialOrdinal - 1) + 1;
    var offset = (last?['byte_offset'] as int? ?? 0) + (last?['byte_length'] as int? ?? 0);
    final now = timestamp ?? DateTime.now().toUtc().toIso8601String();
    for (var item in items) {
      if (!retainedCodexItem(item)) continue;
      item = persistedCodexItem(item);
      if (ordinal < 0 || ordinal == 9223372036854775807) throw StateError('Rollout ordinal exceeds SQLite integer range');
      final line = jsonEncode({'timestamp': now, 'ordinal': ordinal, ...item});
      final length = utf8.encode(line).length + 1;
      db.execute('INSERT INTO rollout_lines(ordinal,timestamp,line,byte_offset,byte_length) VALUES (?,?,?,?,?)', [ordinal, now, line, offset, length]);
      ordinal++; offset += length;
    }
  }
  /// The canonical rows and their materialization share the caller's commit.
  /// Projection savepoints may roll back independently without discarding the
  /// canonical batch, just as Codex keeps its JSONL when projection fails.
  bool tryProject() {
    try { catchUp(); return true; }
    catch (error, stack) {
      log('Canonical rollout retained; thread history projection will retry.', name: 'happen.storage.codex', error: error, stackTrace: stack);
      return false;
    }
  }
  void catchUp() => traceSync('storage.native.projection', () {
    final metadata = db.select("SELECT line FROM rollout_lines WHERE json_extract(line,'\$.type') IS 'session_meta' ORDER BY ordinal LIMIT 1").firstOrNull;
    final visibleFrom = metadata == null ? 0 : jsonDecode(metadata['line'] as String)['payload']['subagent_history_start_ordinal'] as int? ?? 0;
    while (true) {
      final state = db.select('SELECT * FROM thread_history_projection_state WHERE thread_id IS ?', [threadID]).firstOrNull;
      final next = state?['next_rollout_ordinal'] as int? ?? initialOrdinal;
      final offset = state?['next_rollout_byte_offset'] as int? ?? 0;
      final candidates = db.select('SELECT * FROM rollout_lines WHERE ordinal >= ? ORDER BY ordinal LIMIT 256', [next]);
      if (candidates.isEmpty) return;
      final rows = <Map<String, Object?>>[];
      var bytes = 0;
      for (final row in candidates) {
        rows.add(row); bytes += row['byte_length'] as int;
        if (bytes >= 1024 * 1024) break;
      }
      final ownsTransaction = db.raw.autocommit;
      db.execute(ownsTransaction ? 'BEGIN IMMEDIATE' : 'SAVEPOINT history_projection');
      try {
        final current = db.select('SELECT * FROM thread_history_projection_state WHERE thread_id IS ?', [threadID]).firstOrNull;
        if ((current?['next_rollout_ordinal'] ?? initialOrdinal) != next || (current?['next_rollout_byte_offset'] ?? 0) != offset) {
          throw StateError('Projection checkpoint changed');
        }
        var expected = next, end = offset;
        for (final row in rows) {
          if (row['ordinal'] != expected || row['byte_offset'] != end) throw StateError('Rollout position gap');
          if (expected >= visibleFrom) {
            _projectLine(jsonObject(jsonDecode(row['line'] as String)), row['byte_offset'] as int,
              (row['byte_offset'] as int) + (row['byte_length'] as int));
          }
          expected++; end += row['byte_length'] as int;
        }
        db.execute('''INSERT INTO thread_history_projection_state VALUES (?,?,?)
          ON CONFLICT(thread_id) DO UPDATE SET next_rollout_byte_offset=excluded.next_rollout_byte_offset,
          next_rollout_ordinal=excluded.next_rollout_ordinal''', [threadID, end, expected]);
        db.execute(ownsTransaction ? 'COMMIT' : 'RELEASE history_projection');
      } catch (_) {
        db.execute(ownsTransaction ? 'ROLLBACK' : 'ROLLBACK TO history_projection');
        if (!ownsTransaction) db.execute('RELEASE history_projection');
        rethrow;
      }
    }
  }, category: 'storage', attributes: {'storage.architecture': 'codex', 'storage.phase': 'projection'});

  void _projectLine(Json line, int startOffset, int endOffset) {
    final ordinal = line['ordinal'] as int;
    final timestamp = DateTime.tryParse(line['timestamp'] as String)?.millisecondsSinceEpoch;
    if (line['type'] == 'realtime_item') {
      final item = jsonObject(line['payload']);
      db.execute('INSERT INTO thread_realtime_items VALUES (?,?,?,?,?,?) ON CONFLICT(thread_id,item_id) DO NOTHING',
        [threadID, item['id'], ordinal, timestamp, item['type'], jsonEncode(item)]);
      return;
    }
    if (line['type'] != 'event_msg') return;
    final event = jsonObject(line['payload']), type = event['type'], turn = event['turn_id'] as String?;
    if (turn == null) return;
    if (type == 'task_started' || type == 'task_complete' || type == 'turn_aborted') {
      final completed = type != 'task_started';
      final old = db.select('SELECT * FROM thread_turns WHERE thread_id IS ? AND turn_id IS ?', [threadID, turn]).firstOrNull;
      db.execute('''INSERT INTO thread_turns(thread_id,turn_id,root_turn_id,rollout_ordinal,rollout_byte_offset,
        rollout_end_ordinal,rollout_end_byte_offset,status,error_json,started_at,completed_at,duration_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(thread_id,turn_id) DO UPDATE SET
          root_turn_id=coalesce(thread_turns.root_turn_id,excluded.root_turn_id),
          rollout_end_ordinal=excluded.rollout_end_ordinal,rollout_end_byte_offset=excluded.rollout_end_byte_offset,
          status=excluded.status,error_json=excluded.error_json,started_at=excluded.started_at,
          completed_at=excluded.completed_at,duration_ms=excluded.duration_ms
        WHERE thread_turns.rollout_end_ordinal IS NULL AND thread_turns.status IS 'inProgress' ''',
        [threadID, turn, event['root_turn_id'], ordinal, startOffset, completed ? ordinal : null, completed ? endOffset : null,
          completed ? (type == 'turn_aborted' ? 'interrupted' : event['error'] != null ? 'failed' : 'completed') : 'inProgress',
          event['error'] == null ? null : jsonEncode(event['error']), event['started_at'] ?? old?['started_at'], event['completed_at'], event['duration_ms']]);
      _summarize(turn, ordinal);
    }
    if (type != 'item_completed') return;
    final item = projectedCodexItem(jsonObject(event['item']));
    final started = event['started_at_ms'] as int?;
    final completed = (event['completed_at_ms'] as int? ?? 0) == 0 ? null : event['completed_at_ms'];
    final created = started ?? timestamp;
    if (created == null) throw StateError('Missing item creation timestamp');
    db.execute('''INSERT INTO thread_items(thread_id,turn_id,item_id,rollout_ordinal,updated_at_ordinal,
      created_at_ms,started_at_ms,completed_at_ms,item_type,item_json) VALUES (?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(thread_id,turn_id,item_id) DO UPDATE SET updated_at_ordinal=excluded.updated_at_ordinal,
        started_at_ms=coalesce(thread_items.started_at_ms,excluded.started_at_ms),
        completed_at_ms=coalesce(thread_items.completed_at_ms,excluded.completed_at_ms),
        item_type=excluded.item_type,item_json=excluded.item_json''',
      [threadID, turn, item['id'], ordinal, ordinal, created, started, completed, item['type'], jsonEncode(item)]);
    _summarize(turn, ordinal);
  }
  void _summarize(String turn, int ordinal) {
    db.execute(r'''UPDATE thread_turns SET
      first_user_item_id=coalesce(first_user_item_id,(SELECT item_id FROM thread_items
        WHERE thread_id IS ? AND turn_id IS ? AND item_type IS 'userMessage' ORDER BY rollout_ordinal LIMIT 1)),
      final_agent_item_id=coalesce((SELECT item_id FROM thread_items
        WHERE thread_id IS ? AND turn_id IS ? AND item_type IS 'agentMessage'
        AND json_extract(item_json,'$.phase') IS 'final_answer' ORDER BY rollout_ordinal DESC LIMIT 1),
        CASE WHEN status IN ('completed','interrupted','failed') THEN
          (SELECT item_id FROM thread_items WHERE thread_id IS ? AND turn_id IS ?
            AND item_type IS 'agentMessage' AND json_extract(item_json,'$.phase') IS NULL
            ORDER BY rollout_ordinal DESC LIMIT 1) END,final_agent_item_id)
      WHERE thread_id IS ? AND turn_id IS ? AND (rollout_end_ordinal IS ? OR status IS 'inProgress')''',
      [threadID, turn, threadID, turn, threadID, turn, threadID, turn, ordinal]);
  }
  List<Json> items({String? turn, int after = -1, int? updatedAfter, int limit = 100}) => [
    for (final row in db.select('''SELECT * FROM thread_items WHERE thread_id IS ?
      AND (? IS NULL OR turn_id IS ?) AND rollout_ordinal > ?
      AND (? IS NULL OR updated_at_ordinal > ?) ORDER BY rollout_ordinal LIMIT ?''',
      [threadID, turn, turn, after, updatedAfter, updatedAfter, limit])) {...row, 'item': jsonDecode(row['item_json'] as String)},
  ];
}

bool retainedCodexItem(Json item) {
  if (item['type'] == 'event_msg') return const {
    'item_completed', 'token_count', 'thread_goal_updated', 'thread_rolled_back', 'turn_aborted', 'task_started', 'task_complete', 'thread_settings_applied',
  }.contains(item['payload']?['type']);
  if (item['type'] == 'response_item') return const {
    'additional_tools', 'message', 'agent_message', 'reasoning', 'local_shell_call', 'function_call', 'tool_search_call',
    'function_call_output', 'tool_search_output', 'custom_tool_call', 'custom_tool_call_output', 'web_search_call',
    'image_generation_call', 'configuration_update', 'compaction', 'context_compaction',
  }.contains(item['payload']?['type']);
  return const {'session_meta', 'realtime_item', 'compacted', 'turn_context', 'token_usage_record', 'world_state',
    'retained_context', 'security_risk_score', 'dynamic_tools_updated', 'inter_agent_communication', 'inter_agent_communication_metadata'}.contains(item['type']);
}

Json projectedCodexItem(Json item) => switch (requiredString(item, 'type')) {
  'UserMessage' => {'type': 'userMessage', 'id': item['id'], 'clientId': item['client_id'], 'content': item['content']},
  'AgentMessage' => {'type': 'agentMessage', 'id': item['id'], 'text': (item['content'] as List).map((p) => p['text']).join(),
    'phase': item['phase'], 'memoryCitation': item['memory_citation'], 'delivery': item['delivery'], 'questions': item['questions']},
  'Reasoning' => {'type': 'reasoning', 'id': item['id'], 'summary': item['summary_text'], 'content': item['raw_content'] ?? <Object?>[]},
  'FunctionCallOutput' => {'type': 'functionCallOutput', 'id': item['id'], 'name': item['name'], 'namespace': item['namespace'], 'output': item['output']},
  'HookPrompt' => {'type': 'hookPrompt', 'id': item['id'], 'fragments': item['fragments']},
  'Plan' => {'type': 'plan', 'id': item['id'], 'text': item['text']},
  'CommandExecution' => _commandItem(item),
  'McpToolCall' => _mcpItem(item),
  'DynamicToolCall' => {'type': 'dynamicToolCall', 'id': item['id'], 'namespace': item['namespace'], 'tool': item['tool'],
    'arguments': item['arguments'], 'status': _camel(item['status']), 'contentItems': item['content_items'], 'success': item['success'], 'durationMs': _durationMs(item['duration'])},
  'CollabAgentToolCall' => {'type': 'collabAgentToolCall', 'id': item['id'], 'tool': _camel(item['tool']), 'status': _camel(item['status']),
    'senderThreadId': item['sender_thread_id'], 'receiverThreadIds': item['receiver_thread_ids'] ?? <String>[],
    'prompt': item['prompt'], 'model': item['model'], 'reasoningEffort': item['reasoning_effort'],
    'agentsStates': {for (final entry in jsonObject(item['agents_states'] ?? {}).entries) entry.key: _agentState(entry.value)}},
  'SubAgentActivity' => {'type': 'subAgentActivity', 'id': item['id'], 'kind': _camel(item['kind']),
    'agentThreadId': item['agent_thread_id'], 'agentPath': item['agent_path'], 'model': item['model'], 'reasoningEffort': item['reasoning_effort']},
  'WebSearch' => {'type': 'webSearch', 'id': item['id'], 'query': item['query'], 'action': _searchAction(item['action']), 'results': item['results']},
  'ImageView' => {'type': 'imageView', 'id': item['id'], 'path': item['path']},
  'Extension' => _extensionItem(item),
  'ImageGeneration' => {'type': 'imageGeneration', 'id': item['id'], 'status': item['status'], 'result': item['result'],
    'revisedPrompt': item['revised_prompt'], 'savedPath': item['saved_path'], 'transparentBackground': null, 'failure': null, 'generationId': null},
  'EnteredReviewMode' => {'type': 'enteredReviewMode', 'id': item['id'], 'review': item['user_facing_hint']},
  'ExitedReviewMode' => {'type': 'exitedReviewMode', 'id': item['id'], 'review': _reviewText(item['review_output'])},
  'FileChange' => _fileItem(item),
  'ContextCompaction' => {'type': 'contextCompaction', 'id': item['id']},
  _ => throw FormatException('Unsupported canonical TurnItem ${item['type']}'),
};
String? _camel(Object? value) => value == null ? null : (value as String).replaceAllMapped(RegExp(r'_([a-z])'), (m) => m[1]!.toUpperCase());
String? _snake(Object? value) => value == null ? null : (value as String).replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
int? _durationMs(Object? value) => value is Map ? (value['secs'] as int) * 1000 + (value['nanos'] as int) ~/ 1000000 : null;
Json? _duration(Object? value) => value is int ? {'secs': value ~/ 1000, 'nanos': value % 1000 * 1000000} : null;
Json _agentState(Object? state) {
  if (state is String) return {'status': _camel(state), 'message': null};
  final entry = jsonObject(state).entries.single;
  return {'status': _camel(entry.key), 'message': entry.value};
}
Json? _searchAction(Object? value) => value == null ? null : {...jsonObject(value), 'type': _camel(jsonObject(value)['type'])};
final _bearer = RegExp(r'\bBearer[ \t]+[A-Za-z0-9._~+/-]{16,}=*', caseSensitive: false);
final _openaiKey = RegExp(r'sk-[A-Za-z0-9]{20,}');
final _awsKey = RegExp(r'\bAKIA[0-9A-Z]{16}\b');
final _secretAssignment = RegExp(r'''\b(api[_-]?key|token|secret|password)\b(\s*[:=]\s*)(["']?)[^\s"']{8,}''', caseSensitive: false);
String _redact(String value) => value.replaceAll(_bearer, 'Bearer [REDACTED_SECRET]')
  .replaceAll(_openaiKey, '[REDACTED_SECRET]').replaceAll(_awsKey, '[REDACTED_SECRET]')
  .replaceAllMapped(_secretAssignment, (match) => '${match[1]}${match[2]}${match[3]}[REDACTED_SECRET]');
Json _extensionItem(Json item) {
  final type = switch (item['kind']) {'clock.sleep' => 'sleep', 'web.search' => 'webSearch', 'image_gen.generation' => 'imageGeneration',
    _ => throw FormatException('Unsupported extension item ${item['kind']}')};
  return {...item, 'type': type}..remove('kind');
}
Json _commandItem(Json item) {
  final cwd = item['cwd'] as String;
  String quote(String word) => RegExp(r'^[a-zA-Z0-9_/@%+=:,.-]+$').hasMatch(word) ? word : "'${word.replaceAll("'", "'\"'\"'")}'";
  return {'type': 'commandExecution', 'id': item['id'], 'pluginId': item['plugin_id'], 'scriptPath': item['script_path'],
    'processId': item['process_id'], 'command': _redact((item['command'] as List).cast<String>().map(quote).join(' ')), 'cwd': cwd,
    'source': _camel(item['source']), 'status': _camel(item['status']), 'aggregatedOutput': item['aggregated_output'] == '' ? null : item['aggregated_output'],
    'exitCode': item['exit_code'], 'durationMs': _durationMs(item['duration']),
    'commandActions': [for (final raw in item['parsed_cmd'] as List? ?? []) switch (jsonObject(raw)) {
      {'type': 'read', 'cmd': final String cmd, 'name': final String name, 'path': final String path} =>
        {'type': 'read', 'command': _redact(cmd), 'name': name, 'path': path.startsWith('/') ? path : Uri.directory(cwd).resolve(path).path},
      {'type': 'list_files', 'cmd': final String cmd} => {'type': 'listFiles', 'command': _redact(cmd), 'path': raw['path']},
      {'type': 'search', 'cmd': final String cmd} => {'type': 'search', 'command': _redact(cmd), 'query': raw['query'] == null ? null : _redact(raw['query'] as String), 'path': raw['path']},
      {'cmd': final String cmd} => {'type': 'unknown', 'command': _redact(cmd)},
      _ => throw const FormatException('Invalid parsed command'),
    }],
  };
}
Json _fileItem(Json item) {
  final changes = jsonObject(item['changes']), paths = changes.keys.toList()..sort();
  return {'type': 'fileChange', 'id': item['id'], 'status': _camel(item['status']) ?? 'inProgress', 'changes': [for (final path in paths) {
    'path': path, 'kind': {'type': changes[path]['type'], if (changes[path]['type'] == 'update') 'move_path': changes[path]['move_path']},
    'diff': changes[path]['type'] == 'update' ? '${changes[path]['unified_diff']}${changes[path]['move_path'] == null ? '' : '\n\nMoved to: ${changes[path]['move_path']}'}' : changes[path]['content'],
  }]};
}
String _reviewText(Object? value) {
  final output = jsonObject(value ?? {}), findings = (output['findings'] as List? ?? []).map(jsonObject).toList();
  final explanation = (output['overall_explanation'] as String? ?? '').trim();
  final sections = [if (explanation.isNotEmpty) explanation];
  if (findings.isNotEmpty) sections.add([
    findings.length > 1 ? 'Full review comments:' : 'Review comment:',
    for (final finding in findings) ...[
      '', '- ${finding['title']} — ${finding['code_location']['absolute_file_path']}:${finding['code_location']['line_range']['start']}-${finding['code_location']['line_range']['end']}',
      for (final line in const LineSplitter().convert(finding['body'] as String)) '  $line',
    ],
  ].join('\n'));
  return sections.isEmpty ? 'Reviewer failed to output a response.' : sections.join('\n\n');
}
Json _mcpItem(Json item) {
  final result = item['result'] as Json?, duration = item['duration'] as Json?;
  return {'type': 'mcpToolCall', 'id': item['id'], 'server': item['server'], 'tool': item['tool'],
    'status': _camel(item['status']), 'arguments': item['arguments'], 'appContext': item['connectorId'] == null ? null : {
      'connectorId': item['connectorId'], 'linkId': item['linkId'], 'resourceUri': item['mcpAppResourceUri'], 'appName': item['appName'], 'actionName': item['actionName']},
    'mcpAppResourceUri': item['mcpAppResourceUri'], 'mcpAppUi': item['mcpAppUi'], 'pluginId': item['pluginId'], 'readOnlyHint': item['readOnlyHint'],
    'result': result == null ? null : {'content': result['content'], 'structuredContent': result['structuredContent'], '_meta': result['_meta']},
    'error': item['error'], 'durationMs': duration == null ? null : (duration['secs'] as int) * 1000 + (duration['nanos'] as int) ~/ 1000000};
}
Json canonicalCodexItem(Json item) => switch (item['type']) {
  'userMessage' => {'type': 'UserMessage', 'id': item['id'], 'client_id': item['clientId'], 'content': item['content']},
  'agentMessage' => {'type': 'AgentMessage', 'id': item['id'], 'content': [{'type': 'Text', 'text': item['text']}], 'phase': item['phase'],
    'memory_citation': item['memoryCitation'], 'delivery': item['delivery'], 'questions': item['questions']},
  'reasoning' => {'type': 'Reasoning', 'id': item['id'], 'summary_text': item['summary'], 'raw_content': item['content']},
  'mcpToolCall' => {'type': 'McpToolCall', 'id': item['id'], 'server': item['server'], 'tool': item['tool'],
    'arguments': item['arguments'], 'status': item['status'], 'result': item['result'], 'error': item['error'],
    'duration': {'secs': (item['durationMs'] as int? ?? 0) ~/ 1000, 'nanos': ((item['durationMs'] as int? ?? 0) % 1000) * 1000000}},
  'dynamicToolCall' => {'type': 'DynamicToolCall', 'id': item['id'], 'namespace': item['namespace'], 'tool': item['tool'],
    'arguments': item['arguments'], 'status': _snake(item['status']), 'content_items': item['contentItems'],
    'success': item['success'], 'duration': _duration(item['durationMs'])},
  'contextCompaction' => {'type': 'ContextCompaction', 'id': item['id']},
  _ => throw FormatException('Unsupported thread item ${item['type']}'),
};

Json persistedCodexItem(Json item) {
  if (item['type'] != 'event_msg' || item['payload']?['type'] != 'item_completed') return item;
  if (item['payload']?['item']?['type'] == 'CommandExecution' && item['payload']?['item']?['aggregated_output'] is String) {
    final call = jsonObject(item['payload']['item']), output = call['aggregated_output'] as String;
    const marker = '\n... command output truncated for persistence ...\n', max = 64 * 1024;
    final bytes = utf8.encode(output);
    if (bytes.length <= max) return item;
    final remaining = max - utf8.encode(marker).length;
    var left = remaining ~/ 2, right = bytes.length - (remaining - remaining ~/ 2);
    while (left > 0 && bytes[left] & 0xc0 == 0x80) { left--; }
    while (right < bytes.length && bytes[right] & 0xc0 == 0x80) { right++; }
    return {...item, 'payload': {...jsonObject(item['payload']), 'item': {...call,
      'aggregated_output': '${utf8.decode(bytes.sublist(0, left))}$marker${utf8.decode(bytes.sublist(right))}'}}};
  }
  if (item['payload']?['item']?['type'] != 'McpToolCall' || item['payload']?['item']?['result'] == null) return item;
  final call = jsonObject(item['payload']['item']), result = jsonObject(call['result']);
  final serialized = jsonEncode(result), bytes = utf8.encode(serialized);
  const max = 64 * 1024;
  if (bytes.length <= max) return item;
  var budget = max;
  while (true) {
    final preview = budget == 0 ? '' : _middlePreview(serialized, budget);
    final truncated = <String, dynamic>{'content': [{'type': 'text', 'text': preview}], if (result.containsKey('isError')) 'isError': result['isError']};
    final length = utf8.encode(jsonEncode(truncated)).length;
    if (length <= max || budget == 0) return {...item, 'payload': {...jsonObject(item['payload']), 'item': {...call, 'result': truncated}}};
    final scaled = budget * max ~/ length;
    budget = scaled < budget ? scaled : budget - 1;
  }
}
String _middlePreview(String text, int budget) {
  final bytes = utf8.encode(text);
  if (bytes.length <= budget) return text;
  var left = budget ~/ 2, right = bytes.length - (budget - budget ~/ 2);
  while (left > 0 && (bytes[left] & 0xc0) == 0x80) { left--; }
  while (right < bytes.length && (bytes[right] & 0xc0) == 0x80) { right++; }
  final removed = utf8.decode(bytes.sublist(left, right)).runes.length;
  return '${utf8.decode(bytes.sublist(0, left))}…$removed chars truncated…${utf8.decode(bytes.sublist(right))}';
}
