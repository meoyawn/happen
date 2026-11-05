part of '../storage.dart';

const _retainedExecutionMetadata = ['current_cwd', 'agents_snapshot', 'skills_state', 'mcp_snapshot',
  'client_tools_snapshot', 'request_tools', 'effective_reasoning'];

/// Port of Codex paginated_fork's HistoryPosition bookmarks. No source rows or
/// projections are copied. Archive changes collection membership in-place,
/// retaining the immutable prefix used by descendants.
extension ThreadLifecycle on TaskStore {
  List<Json> rolloutPage(Json params) => [for (final row in db.select(
    'SELECT line FROM rollout_lines WHERE ordinal >= ? ORDER BY ordinal LIMIT ?',
    [params['after'] ?? 0, (params['limit'] as int? ?? 100).clamp(1, 500)])) jsonObject(jsonDecode(row['line'] as String))];

  Future<Object?> recall(String method, Json params, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    if (params['agent_name'] != null && params['agent_name'] != '/root') throw const FormatException('Unknown agent');
    final selection = withHistoryLineage(directory, taskId, db, (segments) {
      final entries = <Json>[], windows = <String, Json>{};
      var window = '0';
      for (final segment in segments) {
        final boundaries = segment.db.select("SELECT ordinal,line FROM rollout_lines WHERE ordinal < ? AND json_extract(line,'\$.type') IS 'compacted' ORDER BY ordinal", [segment.end]);
        var boundary = 0;
        for (final row in segment.db.select('SELECT * FROM thread_items WHERE rollout_ordinal < ? ORDER BY rollout_ordinal', [segment.end])) {
          while (boundary < boundaries.length && (boundaries[boundary]['ordinal'] as int) <= (row['rollout_ordinal'] as int)) {
            final line = jsonObject(jsonDecode(boundaries[boundary++]['line'] as String));
            window = '${line['timestamp']}:${line['payload']['window_number'] ?? line['ordinal']}';
          }
          entries.add({'item': jsonDecode(row['item_json'] as String), 'window_id': window,
            'seq': row['rollout_ordinal'], 'created_at': DateTime.fromMillisecondsSinceEpoch(row['created_at_ms'] as int, isUtc: true).toIso8601String()});
          final group = windows.putIfAbsent(window, () => {'window_id': window, 'item_count': 0, 'first_seq': row['rollout_ordinal']});
          group['item_count'] = (group['item_count'] as int) + 1; group['last_seq'] = row['rollout_ordinal'];
        }
        // A compacted ancestor may end before its first item in the new window.
        while (boundary < boundaries.length) {
          final line = jsonObject(jsonDecode(boundaries[boundary++]['line'] as String));
          window = '${line['timestamp']}:${line['payload']['window_number'] ?? line['ordinal']}';
        }
      }
      return (entries: entries, windows: windows.values.toList());
    });
    final recent = params['recent_first'] != false;
    if (method == 'history.list_windows') return (recent ? selection.windows.reversed : selection.windows)
      .take((params['limit'] as int? ?? 20).clamp(1, 100)).toList();
    final result = <Json>[];
    for (final entry in recent ? selection.entries.reversed : selection.entries) {
      cancellation.throwIfCancelled();
      final item = jsonObject(entry['item']);
      final text = item['text'] as String? ?? (item['type'] == 'userMessage' ?
        (item['content'] as List).where((part) => part['type'] == 'text').map((part) => part['text']).join('\n') : jsonEncode(item));
      if (params['item_id'] != null && item['id'] != params['item_id']) continue;
      if (params['window_id'] != null && entry['window_id'] != params['window_id']) continue;
      if (params['tool_name'] != null && item['tool'] != params['tool_name']) continue;
      if (params['tool_namespace'] != null && (item['namespace'] ?? item['server']) != params['tool_namespace']) continue;
      final role = item['type'] == 'userMessage' ? 'user' : item['type'] == 'agentMessage' || item['type'] == 'reasoning' ? 'assistant' : 'tool';
      if (params['role'] != null && params['role'] != role) continue;
      if (params['query'] case final String query when !text.contains(query)) continue;
      final start = (params['offset_chars'] as int? ?? (method == 'history.search_contents' ? text.indexOf(params['query'] as String) : 0)).clamp(0, text.length);
      final limit = (params['limit_chars'] as int? ?? params['max_chars_per_item'] as int? ?? 1500).clamp(1, 16000);
      final snippet = text.substring(start, (start + limit).clamp(start, text.length));
      result.add({'item_id': item['id'], 'window_id': entry['window_id'], 'seq': entry['seq'], 'created_at': entry['created_at'], 'role': role,
        'type': item['type'], 'content': snippet, 'truncated_content': snippet, 'total_chars': text.length, 'offset_chars': start});
      if (result.length >= (params['limit'] as int? ?? 20).clamp(1, 200)) break;
      await cancellableDelay(Duration.zero, cancellation);
    }
    if (method == 'history.read_item') {
      if (result.isEmpty) throw StateError('History item not found');
      return result.single;
    }
    return result;
  }
  Json archive(bool archived) {
    final time = archived ? DateTime.now().toUtc().toIso8601String() : null;
    return append(archived ? 'task.archived' : 'task.unarchived', {'archived_at': time},
      metadata: {'archived_at': time, if (archived) 'mcp_event_subscriptions': <String, Object?>{}});
  }
  Json maintain() {
    if (metadata('archived_at') == null) return {'archived': false};
    return {'archived': true, 'checkpointed': db.select('PRAGMA wal_checkpoint(TRUNCATE)').single.values.first == 0};
  }
  Json forkSnapshot() => {'history_base': _forkPosition(), 'config': metadata('config'),
    'has_user_message': withHistoryLineage(directory, taskId, db, (segments) => segments.any((segment) => segment.db.select(
      "SELECT 1 FROM thread_items WHERE item_type IS 'userMessage' AND rollout_ordinal < ? LIMIT 1", [segment.end]).isNotEmpty)),
    'archived': metadata('archived_at') != null, 'metadata': {
      for (final key in _retainedExecutionMetadata)
        if (metadata(key) case final value?) key: value,
    }};
  void initializeFork(Json snapshot) {
    final base = jsonObject(snapshot['history_base']);
    final config = {...jsonObject(snapshot['config']), 'task_id': taskId, 'history_base': base};
    // Same immutable lineage as a saved fork; this connection may be :memory:.
    // No ancestor context or projection rows are copied into the child.
    db.execute('BEGIN');
    try {
      _metadata({...jsonObject(snapshot['metadata'] ?? {}), 'config': config,
        'history_base': base, 'title': snapshot['title'] ?? 'Side chat'});
      append('task.created', config);
      final suffix = (snapshot['items'] as List? ?? []).map(jsonObject).toList();
      if (suffix.isNotEmpty) {
        final input = modelContext().map(ConversationItem.fromJson).toList();
        final completed = input.expand((item) => item.content)
          .where((part) => part['type'] == 'tool_result').map((part) => part['call_id']).toSet();
        appendBatch([
          for (final call in input.expand((item) => item.calls)) if (!completed.contains(call.id))
            {'type': 'context.injected', 'data': {'item': ConversationItem.toolResult(call,
              'This call belongs to the parent session. Its result was not available at the side conversation boundary.', isError: true).toJson()}},
          for (final item in suffix) {'type': 'context.injected', 'data': {'item': item}},
        ]);
      }
      db.execute('COMMIT');
    } catch (_) { db.execute('ROLLBACK'); rethrow; }
  }

  Json _forkPosition({String? lastTurnId, String? beforeTurnId}) {
    if (lastTurnId != null && beforeTurnId != null) throw const FormatException('Specify only one fork boundary');
    native.catchUp();
    if (lastTurnId != null || beforeTurnId != null) {
      return readStoredSession(db, 'thread/boundary', {'lastTurnId': lastTurnId, 'beforeTurnId': beforeTurnId}, directory: directory, id: taskId);
    }
    final last = db.select('SELECT ordinal,byte_offset+byte_length AS end FROM rollout_lines ORDER BY ordinal DESC LIMIT 1').firstOrNull;
    if (last == null) throw StateError('No rollout found for thread');
    return {'thread_id': taskId, 'end_ordinal_exclusive': (last['ordinal'] as int) + 1, 'end_byte_offset': last['end']};
  }

  Future<void> fork(String childId, {int? through, String? lastTurnId, String? beforeTurnId, CancellationToken? cancellation}) async {
    cancellation?.throwIfCancelled(); validateTaskId(childId);
    final base = _forkPosition(lastTurnId: lastTurnId, beforeTurnId: beforeTurnId);
    final target = Directory('$directory/tasks/$childId');
    if (target.existsSync()) throw StateError('Destination exists');
    final stage = Directory('$directory/staging/${newId()}')..createSync(recursive: true);
    final child = TaskStore(stage.path, childId);
    try {
      child.db.execute('BEGIN');
      final config = {...jsonObject(metadata('config') ?? {}), 'task_id': childId,
        'history_base': base, 'forked_from_id': taskId};
      child._metadata({'history_base': base, 'forked_from_id': taskId, 'config': config,
        for (final key in _retainedExecutionMetadata)
          if (metadata(key) case final value?) key: value});
      for (final row in db.select('SELECT * FROM kv')) {
        child.db.execute('INSERT INTO kv VALUES (?,?,?,?)', [row['key'], row['value'], row['time_created'], row['time_updated']]);
      }
      child.state = {...child.state, 'window': state['window'], if (state['tokens'] != null) 'tokens': state['tokens']};
      child._runtime(child.state);
      child.append('task.created', config);
      if (_getGoal() case final sourceGoal?) child.goal('snapshot', {'goal': sourceGoal});
      if (lastTurnId == null && beforeTurnId == null) {
        final active = db.select("SELECT turn_id,started_at FROM thread_turns WHERE status IS 'inProgress' ORDER BY rollout_ordinal DESC LIMIT 1").firstOrNull;
        if (active != null) child.native.append([{'type': 'event_msg', 'payload': {
          'type': 'turn_aborted', 'turn_id': active['turn_id'], 'started_at': active['started_at'],
          'completed_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }}]);
      }
      child.db.execute('COMMIT');
      child.close();
      await cancellableDelay(Duration.zero, cancellation);
      Directory('${stage.path}/tasks/$childId').renameSync(target.path);
    } finally { child.close(); stage.deleteSync(recursive: true); }
  }

  /// Portable export flattens the referenced prefix into native RolloutLines.
  /// Happen reconstruction payloads are optional extensions, not an event log.
  Future<void> exportTo(String destination, {CancellationToken? cancellation}) async {
    cancellation?.throwIfCancelled();
    if (metadata('status') == 'running') throw StateError('Export requires an idle task');
    if (File(destination).existsSync()) throw StateError('Export destination exists');
    final temporary = File('$destination.partial-${newId()}')..parent.createSync(recursive: true);
    final sink = temporary.openWrite();
    try {
      final lines = withHistoryLineage(directory, taskId, db, (segments) => [
        for (final segment in segments)
          ...segment.db.select('SELECT line,happen_context FROM rollout_lines WHERE ordinal < ? ORDER BY ordinal', [segment.end])
            .map((row) => {'line': jsonDecode(row['line'] as String), 'context': row['happen_context']}),
      ]);
      final config = {...jsonObject(metadata('config') ?? {})}..remove('history_base');
      sink.writeln(jsonEncode({'type': 'session_meta', 'timestamp': DateTime.now().toUtc().toIso8601String(), 'ordinal': 0,
        'payload': {'id': taskId, 'history_mode': 'paginated', 'cwd': jsonObject(metadata('config') ?? {})['cwd'],
          'model_provider': jsonObject(metadata('config') ?? {})['provider']},
        'happen': {'configuration': config,
          'metadata': {for (final key in _retainedExecutionMetadata) if (metadata(key) case final value?) key: value},
          'runtime': {for (final key in ['window', 'tokens']) if (state[key] != null) key: state[key]},
          'kv': [for (final row in db.select('SELECT * FROM kv ORDER BY key')) {...row}],
          'goal': _getGoal(),
        }}));
      var ordinal = 1;
      for (final entry in lines) {
        cancellation?.throwIfCancelled();
        final line = jsonObject(entry['line']);
        if (line['type'] == 'session_meta') continue;
        sink.writeln(jsonEncode({...line, 'ordinal': ordinal++,
          if (entry['context'] != null) 'happen_context': jsonDecode(entry['context'] as String)}));
        if (ordinal % 100 == 0) { await sink.flush(); await cancellableDelay(Duration.zero, cancellation); }
      }
      await sink.flush(); await sink.close();
      cancellation?.throwIfCancelled(); await temporary.rename(destination);
    } catch (_) { await sink.close(); if (temporary.existsSync()) temporary.deleteSync(); rethrow; }
  }
}

Future<String> _importRollout(String directory, String source, {String? operationId,
    required Future<String> Function(Json config) newTaskId, CancellationToken? cancellation}) async {
  cancellation?.throwIfCancelled();
  final stage = Directory('$directory/staging/${newId()}')..createSync(recursive: true);
  TaskStore? store;
  try {
    final token = cancellation ?? CancellationToken(), input = ownStream(File(source).openRead(), token);
    var expected = 0, batchSteps = 0, batchBytes = 0;
    Json? config, extension;
    try {
      await for (final raw in boundedLines(input.stream, maxBytes: maxContextBytes + maxFrameBytes)) {
        token.throwIfCancelled();
        final line = jsonObject(jsonDecode(raw));
        if (line['ordinal'] != expected++ || line['timestamp'] is! String || !retainedCodexItem(line)) throw const FormatException('Invalid rollout record');
        if (store == null) {
          if (line['type'] != 'session_meta' || line['payload']?['history_base'] != null) throw const FormatException('Import requires a standalone rollout');
          final payload = jsonObject(line['payload']);
          extension = jsonObject(line['happen'] ?? {});
          config = jsonObject(extension['configuration'] ?? {'provider': payload['model_provider'], 'cwd': payload['cwd']})..remove('history_base');
          final id = await newTaskId(config); validateTaskId(id);
          if (Directory('$directory/tasks/$id').existsSync()) throw StateError('Destination exists');
          // Choose the final identity before materialization. Staging keeps the
          // import private until complete, without a second identity-repair pass.
          store = TaskStore(stage.path, id);
          store.db.execute('BEGIN');
          store._metadata({'config': config});
          line['payload'] = {...payload, 'id': id};
        } else if (batchSteps >= 256 || batchBytes >= 1024 * 1024) {
          // Codex materialization checkpoints complete records at these exact
          // boundaries. Canonical rows and projected rows share that commit.
          store.native.catchUp(); store.db.execute('COMMIT');
          await cancellableDelay(Duration.zero, token);
          store.db.execute('BEGIN'); batchSteps = 0; batchBytes = 0;
        }
        if (line['type'] == 'turn_context') {
          final context = jsonObject(line['payload']);
          config = {...config!, if (context['model'] != null) 'model': context['model'], if (context['cwd'] != null) 'cwd': context['cwd']};
          if (context['effort'] != null) store._metadata({'effective_reasoning': context['effort']});
        }
        store.native.record([{'type': line['type'], 'payload': line['payload']}], timestamp: line['timestamp'] as String);
        if (line['happen_context'] != null) store.db.execute('UPDATE rollout_lines SET happen_context=? WHERE ordinal IS ?', [jsonEncode(line['happen_context']), expected - 1]);
        batchSteps++; batchBytes += utf8.encode(raw).length + 1;
      }
    } finally { await input.close(); }
    if (store == null || config == null) throw const FormatException('Empty rollout');
    final id = store.taskId;
    final metadata = jsonObject(extension?['metadata'] ?? {});
    store._metadata({for (final key in _retainedExecutionMetadata) if (metadata.containsKey(key)) key: metadata[key],
      'config': {...config, if (config.containsKey('task_id')) 'task_id': id}, 'import_operation': operationId});
    for (final raw in extension?['kv'] as List? ?? <Json>[]) {
      final row = jsonObject(raw);
      store.db.execute('INSERT INTO kv VALUES (?,?,?,?)', [requiredString(row, 'key'), requiredString(row, 'value'), row['time_created'], row['time_updated']]);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    store.state = {...store.state, ...jsonObject(extension?['runtime'] ?? {}), 'created': now, 'updated': now};
    store._runtime(store.state);
    if (extension?['goal'] case final Map<String, Object?> goal) {
      store.goal('snapshot', {'goal': goal});
    }
    store.native.catchUp(); store.db.execute('COMMIT');
    store.close();
    cancellation?.throwIfCancelled();
    Directory('$directory/tasks').createSync(recursive: true);
    Directory('${stage.path}/tasks/$id').renameSync('$directory/tasks/$id');
    return id;
  } finally { store?.close(); stage.deleteSync(recursive: true); }
}
