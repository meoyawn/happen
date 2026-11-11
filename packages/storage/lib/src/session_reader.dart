import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:telemetry/telemetry.dart';

typedef HistorySegment = ({TracedDatabase db, String id, int end});

String? _turnDiff(TracedDatabase db, String turn, int start, int end) {
  final row = db.select(r'''SELECT json_extract(line,'$.payload.unified_diff') AS diff
    FROM rollout_lines WHERE ordinal >= ? AND ordinal < ?
      AND json_extract(line,'$.type') IS 'event_msg'
      AND json_extract(line,'$.payload.type') IS 'turn_diff'
      AND json_extract(line,'$.payload.turn_id') IS ?
    ORDER BY ordinal DESC LIMIT 1''', [start, end, turn]).firstOrNull;
  return row?['diff'] as String?;
}

Json _turnMetadata(TracedDatabase db, Map<String, Object?> row, int end) {
  final terminal = row['rollout_end_ordinal'] != null && (row['rollout_end_ordinal'] as int) < end;
  return {'id': row['turn_id'], 'rootTurnId': row['root_turn_id'], 'order': row['rollout_ordinal'],
    'diff': _turnDiff(db, row['turn_id'] as String, row['rollout_ordinal'] as int, end),
    'status': terminal ? row['status'] : 'inProgress',
    'error': !terminal || row['error_json'] == null ? null : jsonDecode(row['error_json'] as String),
    'startedAt': row['started_at'], 'completedAt': terminal ? row['completed_at'] : null,
    'durationMs': terminal ? row['duration_ms'] : null};
}

Object? storedMetadata(TracedDatabase db, String key) {
  final row = db.select('SELECT value FROM metadata WHERE key IS ?', [key]).firstOrNull;
  return row == null ? null : jsonDecode(row['value'] as String);
}

/// Only called inside caller-cancellable read isolates. A fresh WAL connection
/// can see SQLITE_BUSY_RECOVERY while another process opens/checkpoints it.
/// Close the failed snapshot before yielding; do not block in a native busy
/// handler or quietly misclassify a live session as a corrupt neighbor.
Future<T> withReadOnlySnapshot<T>(String path, T Function(TracedDatabase) read) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
  var reported = false;
  try {
    while (true) {
      TracedDatabase? db;
      try {
        db = openTracedDatabase(path, mode: OpenMode.readOnly);
        db.execute('PRAGMA query_only=ON'); db.execute('BEGIN');
        return read(db);
      } on SqliteException catch (error, stack) {
        if (error.resultCode != 5) rethrow;
        if (!reported) { traceInstant('sqlite.read.busy', category: 'sqlite', attributes: {'db.name': path}); reported = true; }
        // Release the connection before the cancellable delay/retry.
        db?.close(); db = null;
        try { await cancellableDelay(const Duration(milliseconds: 20), deadline); }
        on TimeoutException { Error.throwWithStackTrace(error, stack); }
      } finally { db?.close(); }
    }
  } finally { deadline.cancel(); }
}

/// Codex RolloutLineage: ancestor ranges are immutable, exclusive bookmarks.
/// Every ancestor is opened read-only; a child never obtains its writer.
T withHistoryLineage<T>(String directory, String id, TracedDatabase own, T Function(List<HistorySegment>) read, {bool localOnly = false}) {
  final opened = <TracedDatabase>[], segments = <HistorySegment>[], seen = <String>{};
  var db = own, current = id;
  int? end;
  try {
    while (true) {
      if (!seen.add(current)) throw const FormatException('Invalid paginated history lineage: cycle detected');
      final latest = db.select('SELECT max(ordinal) AS n FROM rollout_lines').single['n'] as int?;
      segments.add((db: db, id: current, end: end ?? (latest ?? -1) + 1));
      if (localOnly) break;
      final meta = db.select("SELECT line FROM rollout_lines WHERE json_extract(line,'\$.type') IS 'session_meta' ORDER BY ordinal LIMIT 1").firstOrNull;
      final payload = meta == null ? null : jsonObject(jsonDecode(meta['line'] as String)['payload']);
      if (payload != null && payload['id'] != current) throw const FormatException('Invalid paginated history lineage: source identity does not match its thread');
      final base = payload?['history_base'];
      if (base == null) break;
      final parent = requiredString(jsonObject(base), 'thread_id');
      validateTaskId(parent);
      final ordinal = base['end_ordinal_exclusive'], bytes = base['end_byte_offset'];
      if (ordinal is! int || ordinal < 1 || bytes is! int || bytes < 1) throw const FormatException('Invalid paginated history position');
      final path = File('$directory/tasks/$parent/history.sqlite');
      if (!path.existsSync()) throw const FormatException('Invalid paginated history lineage: missing source rollout');
      final managed = Directory('$directory/tasks').resolveSymbolicLinksSync();
      if (!path.resolveSymbolicLinksSync().startsWith('$managed${Platform.pathSeparator}')) {
        throw const FormatException('Invalid paginated history lineage: source escapes storage root');
      }
      db = openTracedDatabase(path.path, mode: OpenMode.readOnly);
      opened.add(db);
      // Concurrent cold readers can briefly compete to recover an ancestor's
      // WAL index. Keep the wait on this read-only connection, never its writer.
      db.execute('PRAGMA busy_timeout=1000');
      db.execute('PRAGMA query_only=ON'); db.execute('BEGIN');
      final position = db.select('SELECT byte_offset+byte_length AS end FROM rollout_lines WHERE ordinal IS ?', [ordinal - 1]).firstOrNull;
      if (position == null || position['end'] != bytes) throw const FormatException('Invalid paginated history lineage: cutoff outside source rollout');
      end = ordinal; current = parent;
    }
    return read(segments.reversed.toList());
  } finally { for (final connection in opened.reversed) { connection.close(); } }
}

Future<Json> readSession(String directory, String sessionID, String method, Json params,
    {required CancellationToken cancellation}) async {
  cancellation.throwIfCancelled(); validateTaskId(sessionID);
  final carrier = currentTrace?.carrier();
  return CancellableIsolate.run(() => withTrace(traceContextFrom(carrier, service: 'storage'), () =>
    withReadOnlySnapshot('$directory/tasks/$sessionID/history.sqlite',
      (db) => readStoredSession(db, method, params, directory: directory, id: sessionID))), cancellation);
}

/// Codex StateRuntime-style public metadata, kept separate from canonical
/// history and from private subscription credentials.
Json catalogThread(TracedDatabase db, String directory, String id) {
  final config = storedMetadata(db, 'config');
  if (config is! Map || config['ephemeral'] == true) return {'id': id, 'missing': true};
  final page = readStoredSession(db, 'thread/read', {}, directory: directory, id: id);
  final subscriptions = jsonObject(storedMetadata(db, 'mcp_event_subscriptions') ?? {});
  final receipts = (storedMetadata(db, 'mcp_event_receipts') as List? ?? []).cast<String>().toSet();
  final pending = (page['pending'] as List).map(jsonObject).any((item) => receipts.contains(item['id']));
  return {'id': id, 'thread': page['thread'], 'archived': page['archived'], 'sequence': page['through'],
    'recovery': page['archived'] != true && (subscriptions.isNotEmpty || pending)};
}

Future<List<Json>> readCatalogThreads(String directory, List<String> ids, {required CancellationToken cancellation}) {
  cancellation.throwIfCancelled();
  return CancellableIsolate.run(() async {
    final result = <Json>[];
    for (final id in ids) {
      try {
        validateTaskId(id);
        final file = File('$directory/tasks/$id/history.sqlite');
        if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file) {
          result.add({'id': id, 'missing': true}); continue;
        }
        result.add(await withReadOnlySnapshot(file.path, (db) => catalogThread(db, directory, id)));
      } on FormatException { /* An invalid neighbor cannot hide healthy metadata. */ }
      on SqliteException catch (error) { if (error.resultCode == 5) rethrow; }
    }
    return result;
  }, cancellation);
}

/// Startup inventory only: never opens a writer, loads a thread, copies lineage
/// or subscribes a client. Subscription secrets stay in this private host path,
/// outside portable history/fork metadata and ordinary thread reads.
Future<List<Json>> readMcpEventOwners(String directory, {required List<String> threadIds, required CancellationToken cancellation}) async {
  cancellation.throwIfCancelled();
  return CancellableIsolate.run(() async {
    final result = <Json>[];
    for (final id in threadIds) {
      try {
        validateTaskId(id);
        final path = File('$directory/tasks/$id/history.sqlite');
        if (FileSystemEntity.typeSync(path.path, followLinks: false) != FileSystemEntityType.file) continue;
        final owner = await withReadOnlySnapshot<Json?>(path.path, (db) {
          if (storedMetadata(db, 'archived_at') != null) return null;
          final subscriptions = jsonObject(storedMetadata(db, 'mcp_event_subscriptions') ?? {});
          final receipts = (storedMetadata(db, 'mcp_event_receipts') as List? ?? []).cast<String>().toSet();
          final row = db.select('SELECT data FROM happen_runtime').firstOrNull;
          final state = row == null ? <String, dynamic>{} : jsonObject(jsonDecode(row['data'] as String));
          final pending = jsonObject(state['pendingInputs'] ?? {}).values.map(jsonObject).any((item) => receipts.contains(item['id']));
          if (subscriptions.isEmpty && !pending) return null;
          final config = jsonObject(storedMetadata(db, 'config'));
          return {'threadId': id, 'cwd': config['cwd'], 'subscriptions': subscriptions.values.toList(), 'pending': pending};
        });
        if (owner != null) result.add(owner);
      } on FormatException { /* One corrupt neighbor cannot hide other subscriptions. */ }
      on SqliteException catch (error) {
        if (error.resultCode == 5) rethrow;
        /* An incomplete/unrelated session is not a subscription owner. */
      }
    }
    return result;
  }, cancellation);
}

Json readStoredSession(TracedDatabase db, String method, Json params, {required String directory, required String id}) {
  final stateRow = db.select('SELECT data FROM happen_runtime').firstOrNull;
  final state = stateRow == null ? <String, dynamic>{} : jsonObject(jsonDecode(stateRow['data'] as String));
  final pending = jsonObject(state['pendingInputs'] ?? {}).values.toList();
  if (method == 'session.inbox') return {'data': pending};
  final config = jsonObject(storedMetadata(db, 'config') ?? {});
  final archived = storedMetadata(db, 'archived_at') != null;
  return withHistoryLineage(directory, id, db, (segments) {
    if (method == 'thread/image/read') return _readInspectedImage(segments, requiredString(params, 'itemId'));
    for (final segment in params['includeTurns'] != true && params['includeRecentHistory'] != true && method == 'thread/read' ? <HistorySegment>[] : segments) {
      final projected = segment.db.select('SELECT next_rollout_ordinal FROM thread_history_projection_state').firstOrNull?['next_rollout_ordinal'] as int? ?? 0;
      if (projected < segment.end) return {'needsProjection': segment.id};
    }
    if (method == 'thread/item/read') {
      final turn = requiredString(params, 'turnId'), item = requiredString(params, 'itemId');
      for (final segment in segments.reversed) {
        final row = segment.db.select('SELECT item_json FROM thread_items '
          'WHERE turn_id IS ? AND item_id IS ? AND rollout_ordinal < ?', [turn, item, segment.end]).firstOrNull;
        if (row != null) return {'item': jsonDecode(row['item_json'] as String)};
      }
      throw StateError('Item not found in visible thread history');
    }
    if (method == 'thread/items/list' || method == 'thread/turns/list') return _pagedHistory(segments, id, method, params);
    final previewOnly = method == 'thread/read' && params['includeTurns'] != true;
    final turns = <Json>[], items = <Json>[];
    for (final segment in segments) {
      for (final row in method == 'thread/boundary' ? <Map<String, Object?>>[] : segment.db.select(
          'SELECT * FROM thread_items WHERE rollout_ordinal < ? ${previewOnly ? "AND item_type IS 'userMessage'" : ''} ORDER BY rollout_ordinal ${previewOnly ? 'LIMIT 1' : ''}', [segment.end])) {
        final value = jsonObject(jsonDecode(row['item_json'] as String));
        items.add({'turnId': row['turn_id'], 'item': value, 'startedAtMs': row['started_at_ms'],
          'completedAtMs': row['completed_at_ms'], '_ordinal': row['rollout_ordinal']});
      }
      for (final row in previewOnly ? <Map<String, Object?>>[] : segment.db.select('SELECT * FROM thread_turns WHERE rollout_ordinal < ? '
          '${method == 'thread/boundary' ? 'AND turn_id IS ?' : ''} ORDER BY rollout_ordinal',
          [segment.end, if (method == 'thread/boundary') params['lastTurnId'] ?? params['beforeTurnId']])) {
        final previous = turns.where((turn) => turn['id'] == row['turn_id']).firstOrNull;
        turns.remove(previous);
        final metadata = _turnMetadata(segment.db, row, segment.end);
        turns.add({...metadata, 'items': <Json>[], 'itemsView': 'full',
          'diff': metadata['diff'] ?? previous?['diff'], 'startedAt': previous?['startedAt'] ?? row['started_at'],
          '_ordinal': row['rollout_ordinal'], '_source': segment.id,
          '_end': row['rollout_end_ordinal'], '_bytes': row['rollout_end_byte_offset'], '_startBytes': row['rollout_byte_offset']});
      }
    }
    items.sort((a, b) => (a['_ordinal'] as int).compareTo(b['_ordinal'] as int));
    turns.sort((a, b) => (a['_ordinal'] as int).compareTo(b['_ordinal'] as int));
    Json publicTurn(Json turn) => {for (final field in turn.entries) if (!field.key.startsWith('_')) field.key: field.value,
      'items': [for (final entry in items.where((entry) => entry['turnId'] == turn['id'])) {
        ...jsonObject(entry['item']), 'order': entry['_ordinal'],
        'startedAtMs': entry['startedAtMs'], 'completedAtMs': entry['completedAtMs'],
      }]};
    if (method == 'thread/boundary') {
      final name = params['lastTurnId'] ?? params['beforeTurnId'];
      final turn = turns.where((turn) => turn['id'] == name).firstOrNull;
      if (turn == null) throw StateError('Turn not found in visible thread history');
      if (params['lastTurnId'] != null && turn['status'] == 'inProgress') throw StateError('lastTurnId identifies an in-progress turn');
      return {'thread_id': turn['_source'], 'end_ordinal_exclusive': params['beforeTurnId'] != null ? turn['_ordinal'] : (turn['_end'] as int) + 1,
        'end_byte_offset': params['beforeTurnId'] != null ? turn['_startBytes'] : turn['_bytes']};
    }
    final firstUser = items.where((entry) => entry['item']['type'] == 'userMessage').firstOrNull?['item'];
    final preview = firstUser == null ? storedMetadata(db, 'goal_preview') as String? ?? ''
      : (firstUser['content'] as List).where((p) => p['type'] == 'text').map((p) => p['text']).join('\n');
    final thread = <String, dynamic>{'id': id, 'sessionId': id, 'forkedFromId': storedMetadata(db, 'forked_from_id'),
      'parentThreadId': null, 'preview': preview, 'name': storedMetadata(db, 'name'), 'ephemeral': config['ephemeral'] == true,
      'section': null, 'sectionEnteredAt': null, 'projectId': null, 'historyMode': 'paginated',
      'modelProvider': config['provider'] ?? 'openai', 'model': config['model'], 'reasoningEffort': storedMetadata(db, 'effective_reasoning') ?? config['provider_settings']?['reasoning'],
      'createdAt': (state['created'] as int? ?? 0) ~/ 1000, 'updatedAt': (state['updated'] as int? ?? state['created'] as int? ?? 0) ~/ 1000,
      'recencyAt': (state['updated'] as int? ?? state['created'] as int? ?? 0) ~/ 1000,
      'status': {'type': 'notLoaded'}, 'path': config['ephemeral'] == true ? null : '$directory/tasks/$id/history.sqlite', 'cwd': config['cwd'] ?? '',
      'cliVersion': '0.1.0', 'originator': 'happen', 'source': 'appServer', 'threadSource': config['thread_source'],
      'agentNickname': null, 'agentRole': null, 'gitInfo': null,
      'turns': params['includeTurns'] == true ? turns.map(publicTurn).toList() : <Json>[]};
    return {'thread': thread, 'configuration': config, 'reasoning': thread['reasoningEffort'],
      'pending': pending, 'archived': archived, 'tokens': state['tokens'],
      'through': state['sourceSeq'] ?? 0,
      if (params['includeRecentHistory'] == true) ...{
        'history': _pagedHistory(segments, id, 'thread/items/list',
          {'limit': 100, 'sortDirection': 'desc', 'byteLimit': 256 * 1024}),
        'recentTurns': _pagedHistory(segments, id, 'thread/turns/list',
          {'limit': 5, 'itemsView': 'summary'}),
      },
    };
  }, localOnly: config['side_parent_id'] != null);
}

/// Read the image the tool actually inspected, independent of source-file
/// changes. Old rollouts can recover a single image from the immediate output
/// batch; ambiguous batches never substitute a different image.
Json _readInspectedImage(List<HistorySegment> segments, String itemID) {
  for (final segment in segments.reversed) {
    final item = segment.db.select("SELECT rollout_ordinal FROM thread_items WHERE item_id IS ? "
      "AND item_type IS 'imageView' AND rollout_ordinal < ?", [itemID, segment.end]).firstOrNull;
    if (item == null) continue;
    final ordinal = item['rollout_ordinal'] as int;
    final source = segment.db.select('SELECT line FROM rollout_lines WHERE ordinal IS ?', [ordinal]).single;
    final line = jsonObject(jsonDecode(source['line'] as String));
    if (line['payload']?['item']?['image_url'] case final String image) return {'source': image};
    final next = segment.db.select(r'''SELECT line FROM rollout_lines WHERE ordinal > ? AND ordinal < ? AND (
      (json_extract(line,'$.type') IS 'response_item' AND json_type(line,'$.payload.output') IS 'array') OR
      (json_extract(line,'$.type') IS 'event_msg' AND (
        json_extract(line,'$.payload.item.type') IS 'ImageView' OR
        json_extract(line,'$.payload.type') IN ('task_started','task_complete','turn_aborted'))))
      ORDER BY ordinal LIMIT 1''', [ordinal, segment.end]).firstOrNull;
    if (next != null) {
      final value = jsonObject(jsonDecode(next['line'] as String));
      if (value case {'type': 'response_item', 'payload': {'output': final List<Object?> output}}) {
        final images = [for (final part in output)
          if (part case {'type': 'input_image', 'image_url': final String image}) image];
        if (images.length == 1) return {'source': images.single};
      }
    }
    return {'path': requiredString(jsonObject(line['payload']['item']), 'path')};
  }
  throw StateError('Unknown inspected image');
}

Json _pagedHistory(List<HistorySegment> segments, String id, String method, Json params) {
  final itemPage = method == 'thread/items/list';
  final direction = params['sortDirection'] as String? ?? (itemPage ? 'asc' : 'desc');
  if (!{'asc', 'desc'}.contains(direction)) throw const FormatException('Invalid history sort direction');
  final limit = (params['limit'] as int? ?? 100).clamp(1, 500);
  final byteLimit = (params['byteLimit'] as int? ?? maxClientFrameBytes ~/ 2).clamp(4096, maxClientFrameBytes ~/ 2);
  int? anchor;
  final cursor = params['cursor'];
  if (cursor is String) {
    final decoded = jsonObject(jsonDecode(utf8.decode(base64Url.decode(cursor))));
    if (decoded['threadId'] != id || decoded['method'] != method || decoded['turnId'] != params['turnId']) throw const FormatException('History cursor does not match this read');
    anchor = decoded['ordinal'] as int;
  } else if (cursor is Map) {
    if (!itemPage || params['turnId'] == null) throw const FormatException('Item anchors require turnId');
    for (final segment in segments) {
      final row = segment.db.select('SELECT rollout_ordinal FROM thread_items WHERE turn_id IS ? AND item_id IS ? AND rollout_ordinal < ?',
        [params['turnId'], cursor['itemId'], segment.end]).firstOrNull;
      anchor ??= row?['rollout_ordinal'] as int?;
    }
    if (anchor == null) throw const FormatException('Item anchor not found');
  }
  final entries = <({int ordinal, Json value})>[];
  var bytes = 0;
  for (final segment in direction == 'asc' ? segments : segments.reversed) {
    final rows = segment.db.select('SELECT * FROM ${itemPage ? 'thread_items' : 'thread_turns'} WHERE rollout_ordinal < ? '
      '${anchor == null ? '' : 'AND rollout_ordinal ${direction == 'asc' ? '>' : '<'} ?'} '
      '${itemPage && params['turnId'] != null ? 'AND turn_id IS ?' : ''} ORDER BY rollout_ordinal $direction LIMIT ?',
      [segment.end, ?anchor, if (itemPage && params['turnId'] != null) params['turnId'], limit + 1 - entries.length]);
    for (final row in rows) {
      final Json value;
      if (itemPage) {
        value = {'turnId': row['turn_id'], 'item': jsonDecode(row['item_json'] as String),
          'order': row['rollout_ordinal'], 'startedAtMs': row['started_at_ms'], 'completedAtMs': row['completed_at_ms']};
      } else {
        final view = params['itemsView'] as String? ?? 'summary';
        if (!{'summary', 'full', 'notLoaded'}.contains(view)) throw const FormatException('Invalid itemsView');
        final itemRows = view == 'notLoaded' ? <Map<String, Object?>>[] : segment.db.select(
          'SELECT item_json,rollout_ordinal,started_at_ms,completed_at_ms FROM thread_items WHERE turn_id IS ? AND rollout_ordinal < ? '
          '${view == 'summary' ? 'AND item_id IN (?,?)' : ''} ORDER BY rollout_ordinal',
          [row['turn_id'], segment.end, if (view == 'summary') ...[row['first_user_item_id'], row['final_agent_item_id']]]);
        value = {..._turnMetadata(segment.db, row, segment.end), 'itemsView': view,
          'items': [for (final item in itemRows) {...jsonObject(jsonDecode(item['item_json'] as String)),
            'order': item['rollout_ordinal'], 'startedAtMs': item['started_at_ms'], 'completedAtMs': item['completed_at_ms']}]};
      }
      final size = utf8.encode(jsonEncode(value)).length;
      if (size > maxClientFrameBytes - 4096) throw const FormatException('History item exceeds frame budget');
      entries.add((ordinal: row['rollout_ordinal'] as int, value: value));
      bytes += size;
      if (bytes > byteLimit || entries.length > limit) break;
    }
    if (bytes > byteLimit || entries.length > limit) break;
  }
  final page = entries.take(limit).toList();
  if (bytes > byteLimit && page.length > 1) page.removeLast();
  final turns = <String, Json>{};
  if (itemPage) {
    final ids = page.map((entry) => entry.value['turnId'] as String).toSet();
    for (final segment in segments) {
      for (final turn in ids) {
        final row = segment.db.select('SELECT * FROM thread_turns WHERE turn_id IS ? AND rollout_ordinal < ?',
          [turn, segment.end]).firstOrNull;
        if (row != null) turns[turn] = _turnMetadata(segment.db, row, segment.end);
      }
    }
  }
  String cursorFor(int ordinal) => base64Url.encode(utf8.encode(jsonEncode({'threadId': id, 'method': method, 'turnId': params['turnId'], 'ordinal': ordinal})));
  return {'data': page.map((entry) => entry.value).toList(), 'nextCursor': page.isNotEmpty && page.length < entries.length ? cursorFor(page.last.ordinal) : null,
    if (itemPage) 'turns': turns.values.toList(),
    'backwardsCursor': page.isEmpty ? null : cursorFor(page.first.ordinal)};
}
