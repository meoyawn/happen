part of '../storage.dart';

extension _NativeSession on TaskStore {
  ({List<Json> lines, List<Json> context}) _nativeRecord(Json record, Json next) {
        final data = jsonObject(record['data']), type = record['type'];
        final context = modelContextItems(type as String, data).map((item) => item.toJson()).toList();
        final lines = <Json>[];
        if (type == 'task.created') lines.add({'type': 'session_meta', 'payload': {
          'id': taskId, 'timestamp': record['created_at'], 'cwd': data['cwd'], 'originator': 'happen',
          'cli_version': '0.1.0', 'source': 'appServer', 'model_provider': data['provider'], 'history_mode': 'paginated',
          if (data['history_base'] != null) 'history_base': data['history_base'],
          if (data['forked_from_id'] != null) 'forked_from_id': data['forked_from_id'],
        }});
        if (data['tokenUsageRecord'] case final Map<String, Object?> usage) {
          lines.add({'type': 'token_usage_record', 'payload': usage});
        }
        if (type == 'context.compacted') lines.add({'type': 'compacted', 'payload': {
          'message': data['summary'] ?? '', 'replacement_history': gptInput(context.map(ConversationItem.fromJson)),
          'window_number': next['sourceSeq'],
          'compaction_response_id': data['observed_usage']?['response_id'],
          'latest_token_usage_record': next['latestTokenUsageRecord'],
        }});
        for (final item in type == 'context.compacted' ? <Json>[] : context) {
          for (final response in gptInput([ConversationItem.fromJson(item)])) {
            lines.add({'type': 'response_item', 'payload': response});
          }
        }
        for (final raw in record['notifications'] as List) {
          final notification = jsonObject(raw), params = jsonObject(notification['params']);
          final method = notification['method'];
          Json event(String type, Json value) => {'type': 'event_msg', 'payload': {
            'type': type, 'turn_id': params['turnId'], ...value,
          }};
          if (method == 'turn/started') lines.add(event('task_started', {'started_at': params['turn']['startedAt']}));
          if (method == 'turn/completed') lines.add(event(params['turn']['status'] == 'interrupted' ? 'turn_aborted' : 'task_complete', {
            'completed_at': params['turn']['completedAt'], 'error': params['turn']['error'],
          }));
          if (method == 'item/completed') {
            final item = jsonObject(params['item']);
            final nativeItems = [if (type == 'native.item.completed') data,
              ...(data['nativeCompletions'] as List? ?? []).map(jsonObject)];
            final canonical = nativeItems.where((entry) => entry['item']['id'] == item['id']).firstOrNull?['canonicalItem'];
            lines.add(event('item_completed', {'thread_id': taskId, 'item': canonical ?? canonicalCodexItem(item),
              'started_at_ms': item['startedAtMs'], 'completed_at_ms': item['completedAtMs']}));
          }
          if (method == 'thread/tokenUsage/updated') lines.add(event('token_count', {'info': params['tokenUsage']}));
        }
    return (lines: lines, context: context);
  }

  int _persistNative(List<Json> records, Json changes, Json next) {
    final entries = [for (final record in records) (record: record, batch: _nativeRecord(record, next))];
    if (entries.any((entry) => entry.batch.context.isNotEmpty && entry.batch.lines.isEmpty)) {
      throw StateError('Context has no native rollout record');
    }
    final durableRuntime = records.any((record) => const {
      'input.pending', 'input.delivery', 'input.discarded', 'task.forked', 'task.archived', 'task.unarchived',
    }.contains(record['type']));
    if (!entries.any((entry) => entry.batch.lines.isNotEmpty) && changes.isEmpty && !durableRuntime) return 0;
    final nativeCount = _pendingNativeItems.length;
    if (nativeCount > 0) {
      // Foreground exits piggyback on an existing durability boundary. A later
      // streaming delta must neither commit nor announce the queued completion.
      final completions = _pendingNativeItems.take(nativeCount).toList();
      final completion = <String, dynamic>{...records.first, 'type': 'native.completions', 'data': {'nativeCompletions': completions}};
      final notifications = threadNotifications(taskId, completion, next);
      completion['notifications'] = notifications;
      entries.insert(0, (record: completion, batch: _nativeRecord(completion, next)));
      records.first['data'] = {...jsonObject(records.first['data']), 'nativeCompletions': completions};
      records.first['notifications'] = [...notifications, ...records.first['notifications'] as List];
    }
    final ownsTransaction = db.raw.autocommit;
    db.execute(ownsTransaction ? 'BEGIN' : 'SAVEPOINT native_append');
    try {
      for (final entry in entries) {
        final record = entry.record, lines = entry.batch.lines, context = entry.batch.context;
        if (lines.isNotEmpty) {
          final first = native.nextOrdinal;
          native.record(lines, timestamp: record['created_at'] as String);
          if (context.isNotEmpty) {
            // Every response in this batch is represented by the exact neutral
            // context on its first line. Empty markers prevent double replay.
            db.execute("UPDATE rollout_lines SET happen_context='[]',happen_seq=? WHERE ordinal >= ?", [record['seq'], first]);
            db.execute('UPDATE rollout_lines SET happen_context=? WHERE ordinal IS ?', [jsonEncode(context), first]);
          }
        }
      }
      _metadata(changes); _runtime(next);
      if (entries.any((entry) => entry.batch.lines.isNotEmpty)) native.tryProject();
      db.execute(ownsTransaction ? 'COMMIT' : 'RELEASE native_append');
      return nativeCount;
    } catch (_) {
      db.execute(ownsTransaction ? 'ROLLBACK' : 'ROLLBACK TO native_append');
      if (!ownsTransaction) db.execute('RELEASE native_append');
      rethrow;
    }
  }
}
