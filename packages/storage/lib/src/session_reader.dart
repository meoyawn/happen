import 'dart:convert';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'model_context.dart';

/// Each reader opens the session's WAL database read-only. It never initializes
/// schema or writes projections; the session's single writer does that first.
Future<Json> readSession(String directory, String sessionID, String method, Json params,
    {required CancellationToken cancellation}) async {
  cancellation.throwIfCancelled();
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
      if (method == 'session.inbox') return {'data': [
        for (final row in db.select('SELECT * FROM session_inbox ORDER BY enqueued_seq')) {
          'id': (row['id'] as String).replaceFirst(RegExp(r'^msg_'), ''),
          'prompt': decode(row['payload'])['text'], 'attachments': decode(row['payload'])['files'],
          'delivery': row['delivery'], 'reasoning': decode(row['payload'])['metadata']?['reasoning'],
          'created_at': DateTime.fromMillisecondsSinceEpoch(row['time_created'] as int).toUtc().toIso8601String(),
        },
      ]};
      if (method == 'session.context') {
        final latest = db.select('SELECT coalesce(max(seq), 0) AS seq FROM events').single['seq'] as int;
        final fence = cursor.isEmpty ? latest : cursor['through'] as int;
        if (fence < 0 || fence > latest) throw const FormatException('Invalid context cursor');
        final input = readModelContext(db, through: fence);
        final start = cursor.isEmpty ? 0 : cursor['after'] as int;
        if (start < 0 || start > input.length) throw const FormatException('Invalid context cursor');
        final limit = (params['limit'] as int? ?? 100).clamp(1, 200);
        final page = <Json>[];
        var bytes = 0;
        for (final item in input.skip(start).take(limit)) {
          final size = utf8.encode(jsonEncode(item)).length;
          if (page.isNotEmpty && bytes + size > maxClientFrameBytes ~/ 2) break;
          if (size > maxClientFrameBytes - 1024 * 1024) throw const FormatException('Context item exceeds the WebSocket frame budget');
          page.add(item); bytes += size;
        }
        final checkpoint = db.select("SELECT seq FROM events WHERE type = 'context.compacted' AND seq <= ? ORDER BY seq DESC LIMIT 1", [fence]);
        final compaction = checkpoint.isEmpty ? 0 : checkpoint.single['seq'] as int;
        final request = db.select("SELECT data FROM events WHERE type = 'model.started' AND seq <= ? ORDER BY seq DESC LIMIT 1", [fence]);
        final envelope = request.isEmpty ? <String, dynamic>{} : decode(request.single['data']);
        final usage = db.select("SELECT data FROM events WHERE type = 'model.completed' AND seq > ? AND seq <= ? ORDER BY seq DESC LIMIT 1", [compaction, fence]);
        final effort = db.select("SELECT data FROM events WHERE type = 'configuration.updated' AND seq <= ? ORDER BY seq DESC LIMIT 1", [fence]);
        final times = db.select('SELECT min(created_at) AS created, max(created_at) AS updated FROM events WHERE seq <= ?', [fence]).single;
        final window = db.select('SELECT window_id FROM events WHERE seq <= ? ORDER BY seq DESC LIMIT 1', [fence]);
        final counts = <String, int>{};
        for (final item in input) {
          final kind = item['kind'] == 'message'
            ? (item['native']?['harness'] == null ? item['role'] as String : 'context')
            : item['kind'] as String;
          counts[kind] = (counts[kind] ?? 0) + 1;
        }
        final base = input.where((item) => item['native']?['harness']?['context'] == 'model').lastOrNull;
        final archived = db.select("SELECT value FROM metadata WHERE key = 'archived_at'");
        return {
          'sessionID': sessionID,
          'through': db.select('SELECT coalesce(max(seq), 0) AS seq FROM session_event WHERE source_seq <= ?', [fence]).single['seq'],
          'sourceThrough': fence,
          'windowID': window.isEmpty ? null : window.single['window_id'],
          'model': {'providerID': config['provider'], 'id': config['model']},
          'limit': config['provider_settings']?['context_limit'],
          'instructions': envelope['instructions'], 'tools': envelope['tools'],
          if (base != null) 'baseInstructionID': base['id'],
          'settings': config['provider_settings'] ?? {},
          'effectiveReasoning': effort.isEmpty ? (config['provider_settings']?['reasoning']) : decode(effort.single['data'])['effort'],
          'counts': counts, 'inputCount': input.length,
          'tokens': usage.isEmpty ? null : sessionTokens(jsonObject(decode(usage.single['data'])['usage'] ?? {})),
          'created': DateTime.tryParse(times['created'] as String? ?? '')?.millisecondsSinceEpoch,
          'updated': DateTime.tryParse(times['updated'] as String? ?? '')?.millisecondsSinceEpoch,
          'input': page, 'cursor': {
            if (start + page.length < input.length)
              'next': base64Url.encode(utf8.encode(jsonEncode({'through': fence, 'after': start + page.length}))),
          },
          'archived': archived.isNotEmpty && jsonDecode(archived.single['value'] as String) != null,
        };
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
