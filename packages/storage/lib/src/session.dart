part of '../storage.dart';

extension _SessionSchema on TaskStore {
  void _sessionSchema() => db.execute('''
    CREATE TABLE IF NOT EXISTS session_event (
      seq INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
      source_seq INTEGER NOT NULL REFERENCES events(seq), data TEXT NOT NULL
    ) STRICT;
    CREATE INDEX IF NOT EXISTS session_event_source ON session_event(source_seq);
    CREATE TABLE IF NOT EXISTS session_message (
      id TEXT PRIMARY KEY, type TEXT NOT NULL, seq INTEGER NOT NULL UNIQUE,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
    ) STRICT;
    CREATE INDEX IF NOT EXISTS session_message_type_seq ON session_message(type, seq);
    CREATE TABLE IF NOT EXISTS session_part (
      message_id TEXT NOT NULL REFERENCES session_message(id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL, type TEXT NOT NULL, call_id TEXT, data TEXT NOT NULL,
      PRIMARY KEY (message_id, ordinal)
    ) STRICT;
    CREATE INDEX IF NOT EXISTS session_part_call ON session_part(call_id);
    CREATE TABLE IF NOT EXISTS session_inbox (
      id TEXT PRIMARY KEY, type TEXT NOT NULL, payload TEXT NOT NULL,
      delivery TEXT NOT NULL, enqueued_seq INTEGER NOT NULL, time_created INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX IF NOT EXISTS session_inbox_delivery_seq ON session_inbox(delivery, enqueued_seq);
    CREATE TABLE IF NOT EXISTS session_projection (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      through_seq INTEGER NOT NULL, data TEXT NOT NULL
    ) STRICT;
    INSERT OR IGNORE INTO session_projection VALUES (1, 0, '{}');
  ''');

  /// Runs only on the one session writer, inside its event transaction. The
  /// resulting native events are exactly what the WebSocket publishes.
  void _projectSession(List<Json> records) {
    final state = jsonObject(jsonDecode(db.select('SELECT data FROM session_projection').single['data'] as String));
    final inbox = jsonObject(state['inbox'] ?? {});
    for (final record in records) {
      final native = sessionEvents(taskId, record, state);
      record['session_events'] = native;
      for (final event in native) {
        final seq = event['durable']['seq'] as int;
        db.execute('INSERT INTO session_event(seq, id, source_seq, data) VALUES (?, ?, ?, ?)',
          [seq, event['id'], record['seq'], jsonEncode(event)]);
        final payload = jsonObject(event['data']);
        if (event['type'] == 'session.inbox.enqueued') {
          final item = jsonObject(payload['item']);
          db.execute('INSERT OR IGNORE INTO session_inbox(id, type, payload, delivery, enqueued_seq, time_created) VALUES (?, ?, ?, ?, ?, ?)',
            [payload['inboxID'], item['type'], jsonEncode(item), item['delivery'], seq, event['created']]);
        } else if (event['type'] == 'session.inbox.delivered' || event['type'] == 'session.inbox.cancelled') {
          db.execute('DELETE FROM session_inbox WHERE id = ?', [payload['inboxID']]);
        }
        final messages = <String, Json>{};
        final owner = event['data']['assistantMessageID'] as String?;
        final compaction = inbox['compactionID'] as String?;
        for (final row in db.select("SELECT * FROM session_message WHERE id IN (?, ?) OR (type = 'compaction' AND json_extract(data, '\$.status') = 'running')", [owner, compaction])) {
          messages[row['id'] as String] = {
            'id': row['id'], 'type': row['type'], 'time': {'created': row['time_created']},
            ...jsonObject(jsonDecode(row['data'] as String)),
            if (row['type'] == 'assistant') 'content': [
              for (final part in db.select('SELECT data FROM session_part WHERE message_id = ? ORDER BY ordinal', [row['id']]))
                jsonObject(jsonDecode(part['data'] as String)),
            ],
          };
        }
        for (final message in applySessionEvent(messages, event, inbox)) {
          final data = {...message}..remove('id')..remove('type')..remove('content');
          final created = message['time']['created'];
          db.execute('''INSERT INTO session_message(id, type, seq, time_created, time_updated, data)
            VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
            time_updated = excluded.time_updated, data = excluded.data''',
            [message['id'], message['type'], message['metadata']['seq'], created, event['created'], jsonEncode(data)]);
          if (message['type'] != 'assistant') continue;
          db.execute('DELETE FROM session_part WHERE message_id = ?', [message['id']]);
          var ordinal = 0;
          for (final part in message['content'] as List) {
            db.execute('INSERT INTO session_part(message_id, ordinal, type, call_id, data) VALUES (?, ?, ?, ?, ?)',
              [message['id'], ordinal++, part['type'], part['type'] == 'tool' ? part['id'] : null, jsonEncode(part)]);
          }
        }
      }
    }
    state['inbox'] = inbox;
    db.execute('UPDATE session_projection SET through_seq = ?, data = ?',
      [records.last['seq'], jsonEncode(state)]);
  }
}

extension SessionProjection on TaskStore {
  Json? discardSessionInbox(String reason) {
    final ids = db.select('SELECT id FROM session_inbox ORDER BY enqueued_seq')
      .map((row) => (row['id'] as String).replaceFirst(RegExp(r'^msg_'), '')).toList();
    return ids.isEmpty ? null : append('input.discarded', {'ids': ids, 'reason': reason});
  }

  /// Build the read model from the current event log in bounded transactions
  /// on its single writer.
  Future<void> prepareSession({required CancellationToken cancellation}) async {
    _sessionSchema();
    var through = db.select('SELECT through_seq FROM session_projection').single['through_seq'] as int;
    final cutoff = lastSequence;
    while (through < cutoff) {
      cancellation.throwIfCancelled();
      final page = history(after: through, through: cutoff);
      db.execute('BEGIN IMMEDIATE');
      try {
        _projectSession(page);
        db.execute('COMMIT');
      } catch (_) { db.execute('ROLLBACK'); rethrow; }
      through = page.last['seq'] as int;
      await cancellableDelay(Duration.zero, cancellation);
    }
  }
}
