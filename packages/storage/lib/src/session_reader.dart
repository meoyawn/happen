import 'dart:convert';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';

/// Each reader opens the session's WAL database read-only. It never initializes
/// schema or writes projections; the session's single writer does that first.
Future<Json> readSession(String directory, String sessionID, String method, Json params,
    {required CancellationToken cancellation}) async {
  cancellation.throwIfCancelled();
  if (!{'session.message.list', 'session.event.list', 'session.inbox'}.contains(method)) {
    throw ArgumentError('Unknown stored session read: $method');
  }
  validateTaskId(sessionID);
  return await CancellableIsolate.run(() {
    final db = sqlite3.open('$directory/tasks/$sessionID/history.sqlite', mode: OpenMode.readOnly);
    try {
      db.execute('PRAGMA query_only = ON');
      db.execute('BEGIN');
      if (db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_projection'").isEmpty) {
        return {'needsProjection': true};
      }
      final progress = db.select('SELECT through_seq FROM session_projection').single['through_seq'] as int;
      if (progress < (db.select('SELECT coalesce(max(seq), 0) AS seq FROM events').single['seq'] as int)) {
        return {'needsProjection': true};
      }
      Json decode(Object? raw) => jsonObject(jsonDecode(raw as String));
      Json message(Row row) => {
        'id': row['id'], 'type': row['type'],
        'time': {'created': row['time_created']},
        ...decode(row['data']),
        if (row['type'] == 'assistant') 'content': [
          for (final part in db.select('SELECT data FROM session_part WHERE message_id = ? ORDER BY ordinal', [row['id']]))
            decode(part['data']),
        ],
      };
      final cursor = params['cursor'] == null ? <String, dynamic>{}
        : decode(utf8.decode(base64Url.decode(params['cursor'] as String)));
      Json messagePage({int after = 0}) {
        final before = cursor['before'] as int?;
        if (before != null && before < 1) throw const FormatException('Invalid session cursor');
        final limit = (params['limit'] as int? ?? 100).clamp(1, 200);
        final rows = db.select('SELECT * FROM session_message WHERE seq > ? AND (? IS NULL OR seq < ?) ORDER BY seq DESC LIMIT ?',
          [after, before, before, limit + 1]);
        final selected = <Json>[];
        var bytes = 0;
        for (final row in rows.take(limit)) {
          final item = message(row);
          final size = utf8.encode(jsonEncode(item)).length;
          if (selected.isNotEmpty && bytes + size > maxClientFrameBytes ~/ 2) break;
          if (size > maxClientFrameBytes - 1024 * 1024) throw const FormatException('Session message exceeds the WebSocket frame budget');
          selected.add(item);
          bytes += size;
        }
        return {'data': selected.reversed.toList(), 'cursor': {
          if (selected.isNotEmpty && rows.length > selected.length)
            'next': base64Url.encode(utf8.encode(jsonEncode({'before': selected.last['metadata']['seq']}))),
        }};
      }
      final configRow = db.select("SELECT value FROM metadata WHERE key = 'config'");
      final config = configRow.isEmpty ? <String, dynamic>{} : decode(configRow.single['value']);
      final projection = decode(db.select('SELECT data FROM session_projection').single['data']);
      final through = projection['eventSeq'] as int? ?? 0;
      if (method == 'session.event.list') {
        final after = params['after'] as int? ?? 0;
        if (after < 0) throw const FormatException('Invalid session event sequence');
        final limit = (params['limit'] as int? ?? 100).clamp(1, 500);
        final data = <Json>[];
        var bytes = 0;
        for (final row in db.select('SELECT data FROM session_event WHERE seq > ? ORDER BY seq LIMIT ?', [after, limit])) {
          final encoded = row['data'] as String;
          final size = utf8.encode(encoded).length;
          if (data.isNotEmpty && bytes + size > maxClientFrameBytes ~/ 2) break;
          data.add(decode(encoded));
          bytes += size;
        }
        final last = data.lastOrNull?['durable']?['seq'] as int? ?? after;
        return {'data': data, 'through': through, 'cursor': {if (last < through) 'next': last}};
      }
      if (method == 'session.inbox') {
        return {'data': [
          for (final row in db.select('SELECT * FROM session_inbox ORDER BY enqueued_seq')) {
            'id': (row['id'] as String).replaceFirst(RegExp(r'^msg_'), ''),
            'prompt': decode(row['payload'])['text'], 'attachments': decode(row['payload'])['files'],
            'delivery': row['delivery'], 'reasoning': decode(row['payload'])['metadata']?['reasoning'],
            'created_at': DateTime.fromMillisecondsSinceEpoch(row['time_created'] as int).toUtc().toIso8601String(),
          },
        ]};
      }
      return {
        ...messagePage(),
        'through': through, 'configuration': config, 'reasoning': projection['reasoning'],
        'state': projection['inbox'] ?? {},
        'archived': db.select("SELECT value FROM metadata WHERE key = 'archived_at' AND value != 'null'").isNotEmpty,
      };
    } finally { db.close(); }
  }, cancellation);
}
