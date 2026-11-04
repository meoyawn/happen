part of '../storage.dart';

extension _NativeSession on TaskStore {
  void _persistNative(List<Json> records, Json changes, Json next) {
    var transaction = false, recorded = false;
    final ownsTransaction = db.raw.autocommit;
    void begin() {
      if (!transaction) {
        db.execute(ownsTransaction ? 'BEGIN' : 'SAVEPOINT native_append'); transaction = true;
      }
    }
    try {
      for (final record in records) {
        final data = jsonObject(record['data']), type = record['type'];
        final context = modelContextItems(type as String, data).map((item) => item.toJson()).toList();
        final lines = <Json>[];
        if (type == 'task.created') lines.add({'type': 'session_meta', 'payload': {
          'id': taskId, 'timestamp': record['created_at'], 'cwd': data['cwd'], 'originator': 'happen',
          'cli_version': '0.1.0', 'source': 'appServer', 'model_provider': data['provider'], 'history_mode': 'paginated',
          if (data['history_base'] != null) 'history_base': data['history_base'],
          if (data['forked_from_id'] != null) 'forked_from_id': data['forked_from_id'],
        }});
        if (type == 'context.compacted') lines.add({'type': 'compacted', 'payload': {
          'message': data['summary'] ?? '', 'replacement_history': gptInput(context.map(ConversationItem.fromJson)),
          'window_number': next['sourceSeq'],
        }});
        if (data['tokenUsageRecord'] case final Map<String, Object?> usage) {
          lines.add({'type': 'token_usage_record', 'payload': usage});
        }
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
        if (lines.isNotEmpty) {
          begin(); recorded = true;
          final first = native.nextOrdinal;
          native.record(lines, timestamp: record['created_at'] as String);
          if (context.isNotEmpty) {
            // Every response in this batch is represented by the exact neutral
            // context on its first line. Empty markers prevent double replay.
            db.execute("UPDATE rollout_lines SET happen_context='[]',happen_seq=? WHERE ordinal >= ?", [record['seq'], first]);
            db.execute('UPDATE rollout_lines SET happen_context=? WHERE ordinal IS ?', [jsonEncode(context), first]);
          }
        } else if (context.isNotEmpty) {
          throw StateError('Context has no native rollout record');
        }
      }
      // Durable inbox admission and ownership changes cannot wait for a model
      // response. Streaming starts/deltas themselves are never canonical rows.
      final durableRuntime = records.any((record) => const {
        'input.pending', 'input.delivery', 'input.discarded', 'task.forked',
        'task.archived', 'task.unarchived',
      }.contains(record['type']));
      if (recorded || changes.isNotEmpty || durableRuntime) {
        begin(); _metadata(changes); _runtime(next);
        if (recorded) native.tryProject();
        db.execute(ownsTransaction ? 'COMMIT' : 'RELEASE native_append');
      }
    } catch (_) {
      if (transaction) {
        db.execute(ownsTransaction ? 'ROLLBACK' : 'ROLLBACK TO native_append');
        if (!ownsTransaction) db.execute('RELEASE native_append');
      }
      rethrow;
    }
  }
}
