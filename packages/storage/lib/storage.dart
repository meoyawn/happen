import 'dart:convert';
import 'dart:developer' show log;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'src/model_context.dart';

export 'src/owner.dart' show startStore, importHistory;
export 'src/session_reader.dart' show readSession;

part 'src/session.dart';

/// Access this object only from its dedicated SQLite owner isolate.
class TaskStore {
  TaskStore(
    this.directory,
    this.taskId, {
    bool create = true,
  }) {
    validateTaskId(taskId);
    final folder = Directory('$directory/tasks/$taskId');
    if (!create && !File('${folder.path}/history.sqlite').existsSync()) {
      throw StateError('Task does not exist: $taskId');
    }
    folder.createSync(recursive: true);
    db = sqlite3.open('${folder.path}/history.sqlite');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA cache_size = -512');
    db.execute('PRAGMA busy_timeout = 0');
    // Schema initialization must outlive failed event transactions.
    db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        seq INTEGER PRIMARY KEY, type TEXT NOT NULL,
        created_at TEXT NOT NULL, data TEXT NOT NULL,
        id TEXT NOT NULL UNIQUE, window_id TEXT NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS events_type ON events(type, seq);
      CREATE INDEX IF NOT EXISTS events_window ON events(window_id, seq);
      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY, value TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS conversation_events (
        seq INTEGER PRIMARY KEY REFERENCES events(seq) ON DELETE CASCADE,
        data TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS conversation_parts (
        id TEXT PRIMARY KEY, data TEXT NOT NULL
      ) STRICT;
    ''');
    _sessionSchema();
  }
  final String directory, taskId;
  late final Database db;
  int get lastSequence =>
      db.select('SELECT coalesce(max(seq), 0) AS seq FROM events').first['seq']
          as int;

  Json append(String type, Json data, {Json metadata = const {}}) =>
      appendBatch([
        {'type': type, 'data': data},
      ], metadata: metadata).single;

  List<Json> appendBatch(List<Json> events, {Json metadata = const {}}) {
    if (events.isEmpty) {
      throw const FormatException('Empty history transaction');
    }
    final committed = <Json>[];
    db.execute('BEGIN');
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      var window = metadataValue('current_window') as String? ?? '$taskId:0';
      for (final event in events) {
        if (event['type'] == 'context.compacted') window = newId();
        final id = newId();
        db.execute(
          'INSERT INTO events(id, window_id, type, created_at, data) VALUES (?, ?, ?, ?, ?)',
          [
            id,
            window,
            requiredString(event, 'type'),
            now,
            jsonEncode(jsonObject(event['data'])),
          ],
        );
        final committedEvent = <String, dynamic>{
          'seq': db.lastInsertRowId,
          'id': id,
          'window_id': window,
          'type': event['type'],
          'created_at': now,
          'data': event['data'],
        };
        committed.add(committedEvent);
      }
      for (final entry in {...metadata, 'current_window': window}.entries) {
        db.execute(
          'INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [entry.key, jsonEncode(entry.value)],
        );
      }
      // The OpenCode read model and its source facts become visible together.
      // Existing histories catch up through prepareSession before being read.
      final projected = db.select('SELECT through_seq FROM session_projection').single['through_seq'] as int;
      if (projected == (committed.first['seq'] as int) - 1) _projectSession(committed);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    _projectConversation(committed);
    return committed;
  }

  Object? metadata(String key) {
    return metadataValue(key);
  }

  Json archive(bool archived) {
    final timestamp = archived ? DateTime.now().toUtc().toIso8601String() : null;
    return append(
      archived ? 'task.archived' : 'task.unarchived',
      {'archived_at': timestamp}, metadata: {'archived_at': timestamp},
    );
  }

  Json maintain() {
    if (metadataValue('archived_at') == null) return {'archived': false};
    // History remains recoverable. Reclaim the WAL only when SQLite can do so
    // without waiting for another connection; canonical history is never deleted.
    final checkpoint = db.select('PRAGMA wal_checkpoint(TRUNCATE)').single;
    return {'archived': true, 'checkpointed': checkpoint.values.first == 0};
  }

  Object? metadataValue(String key) {
    final result = db.select('SELECT value FROM metadata WHERE key IS ?', [
      key,
    ]);
    return result.isEmpty ? null : jsonDecode(result.first['value'] as String);
  }

  List<Json> history({int after = 0, int limit = 100, int? through,
    bool recentFirst = false, int maxBytes = maxClientFrameBytes, bool conversationView = false}) {
    if (limit < 1 || limit > 500) {
      throw const FormatException('History limit must be 1..500');
    }
    final query = db.prepare(conversationView ? '''
      SELECT e.seq, e.id, e.window_id, e.type, e.created_at, p.seq AS projected,
        coalesce(p.data, CASE
          WHEN e.type IS 'tool.completed' THEN json_object('item', json_extract(e.data, '\$.item'))
          WHEN e.type IS 'context.compacted' THEN json_object('summary', json_extract(e.data, '\$.summary'))
          WHEN e.type IN ('agents.updated', 'skills.updated', 'mcp.updated', 'environment.updated', 'instructions.updated', 'tools.updated') THEN '{}'
          ELSE e.data END) AS data
      FROM events e LEFT JOIN conversation_events p ON p.seq IS e.seq
      WHERE e.seq > ? AND e.seq <= ? ORDER BY e.seq ${recentFirst ? 'DESC' : 'ASC'} LIMIT ?
    ''' : 'SELECT seq, id, window_id, type, created_at, data FROM events WHERE seq > ? AND seq <= ? ORDER BY seq ${recentFirst ? 'DESC' : 'ASC'} LIMIT ?');
    final result = <Json>[];
    final missing = <int>[];
    try {
      final rows = query.selectCursor([after, through ?? lastSequence, limit]);
      var bytes = 0;
      while (rows.moveNext()) {
        final row = rows.current;
        final encoded = row['data'] as String;
        bytes += utf8.encode(encoded).length + 512;
        // A compaction checkpoint may itself fill a page. Never split a record.
        if (result.isNotEmpty && bytes > maxBytes) break;
        final event = <String, dynamic>{
            'seq': row['seq'],
            'id': row['id'],
            'window_id': row['window_id'],
            'type': row['type'],
            'created_at': row['created_at'],
            'data': jsonDecode(encoded),
        };
        final stale = conversationView && (row['projected'] == null || (event['data'] as Json).remove(r'$view') != 1);
        if (stale) missing.add(result.length);
        result.add(conversationView && !stale ? _conversationEvent(event) : event);
      }
    } finally {
      query.close();
    }
    if (missing.isNotEmpty) {
      // Materialize only this page for older databases, never scan a transcript
      // during startup. Failed cache writes are retried from saved events here.
      final projected = _materializeConversation([
        for (final index in missing) result[index],
      ]);
      for (var index = 0; index < missing.length; index++) {
        result[missing[index]] = projected[index];
      }
    }
    return result;
  }

  void _projectConversation(List<Json> events) {
    try {
      _materializeConversation(events);
    } catch (error, stackTrace) {
      log('Failed to update the conversation cache for $taskId; saved events are intact.',
        name: 'happen.storage', level: 900, error: error, stackTrace: stackTrace);
    }
  }

  List<Json> _materializeConversation(List<Json> events) {
    // Display records and their payload references commit together, after the
    // original events. A failed cache update cannot undo a saved tool result.
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = <Json>[];
      final insert = db.prepare('INSERT OR REPLACE INTO conversation_events(seq, data) VALUES (?, ?)');
      try {
        for (final event in events) {
          final display = _projectEvent(event);
          insert.execute([event['seq'], jsonEncode({...jsonObject(display['data']), r'$view': 1})]);
          result.add(display);
        }
      } finally { insert.close(); }
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Json _projectEvent(Json event) {
    final display = _conversationEvent(event);
    Object? part(Object? value, {Json fields = const {}}) {
      final encoded = jsonEncode(value);
      if (encoded.length <= 1024) return value;
      final id = sha256.convert(utf8.encode(encoded)).toString();
      db.execute('INSERT OR IGNORE INTO conversation_parts(id, data) VALUES (?, ?)', [id, encoded]);
      return {...fields, r'$part': '$taskId/$id'};
    }
    Json image(Json value) => jsonObject(part(value, fields: {
      'type': value['type'], 'name': value['name'],
    }));
    final data = {...jsonObject(display['data'])};
    if (event['type'] == 'host_tool.started' || event['type'] == 'tool.started') {
      final key = event['type'] == 'tool.started' ? 'input' : 'arguments';
      final input = data[key];
      if (input is Map || input is String) {
        Object? decoded = input;
        if (input is String) {
          try { decoded = jsonDecode(input); } on FormatException { /* Code is already text. */ }
        }
        if (decoded is Map) {
          final preview = decoded['command'] ?? decoded['cmd'] ?? decoded['filePath'] ?? decoded['path'];
          if (preview is String) {
            final line = preview.split('\n').first;
            data['preview'] = line.length > 240 ? '${line.substring(0, 240)}…' : line;
          }
        }
        data[key] = part(input);
      }
    } else if (event['type'] == 'host_tool.completed') {
      for (final key in ['output', 'error']) {
        if (data.containsKey(key)) data[key] = part(data[key]);
      }
    } else if (event['type'] == 'input.committed' || event['type'] == 'tool.completed') {
      final item = jsonObject(data['item']);
      data['item'] = {...item, 'content': [
        for (final raw in item['content'] as List? ?? [])
          if (raw['type'] == 'image') image(jsonObject(raw))
          else if (event['type'] == 'tool.completed') {
            ...jsonObject(raw),
            if (raw.containsKey('output')) 'output': part(raw['output']),
            if (raw['images'] is List) 'images': [for (final value in raw['images']) image(jsonObject(value))],
          } else raw,
      ]};
    }
    return {...display, 'data': data};
  }

  Object? conversationPart(String id) {
    final rows = db.select('SELECT data FROM conversation_parts WHERE id IS ?', [id]);
    if (rows.isEmpty) throw StateError('Conversation content not found');
    return jsonDecode(rows.single['data'] as String);
  }

  /// One newest-first page. Opening a transcript never requires replaying it.
  Json historyPage({int? before, int limit = 100}) {
    if (before != null && before < 1) throw const FormatException('Invalid history cursor');
    final through = before == null ? lastSequence : before - 1;
    Json? configuration;
    final summary = <Json>[];
    if (before == null) {
      final rows = db.select("SELECT max(seq) AS seq FROM events WHERE type = 'task.created'");
      final sequence = rows.single['seq'] as int?;
      if (sequence != null) configuration = history(after: sequence - 1, limit: 1, conversationView: true).single;
      // Codex's turn summaries include the first user item independently of
      // the newest item page. A long tool run must not hide its opening prompt.
      final turns = db.select("SELECT seq FROM events WHERE type IS 'turn.started' AND seq <= ? ORDER BY seq DESC LIMIT 5", [through]);
      var end = through;
      for (final turn in turns) {
        final start = turn['seq'] as int;
        summary.add(history(after: start - 1, limit: 1, conversationView: true).single);
        final inputs = db.select("SELECT seq FROM events WHERE type IS 'input.committed' AND seq > ? AND seq <= ? ORDER BY seq LIMIT 1", [start, end]);
        final firstInput = inputs.firstOrNull?['seq'] as int?;
        if (firstInput != null) summary.add(history(after: firstInput - 1, limit: 1, conversationView: true).single);
        final outputs = db.select("SELECT seq FROM events WHERE type IS 'model.completed' AND seq > ? AND seq <= ? ORDER BY seq DESC LIMIT 1", [start, end]);
        final lastOutput = outputs.firstOrNull?['seq'] as int?;
        if (lastOutput != null) summary.add(history(after: lastOutput - 1, limit: 1, conversationView: true).single);
        final terminals = db.select("SELECT max(seq) AS seq FROM events WHERE type IN ('turn.completed', 'turn.failed', 'turn.cancelled') AND seq > ? AND seq <= ?", [start, end]);
        final terminal = terminals.single['seq'] as int?;
        if (terminal != null) summary.add(history(after: terminal - 1, limit: 1, conversationView: true).single);
        end = start - 1;
      }
    }
    final data = history(through: through, limit: limit, recentFirst: true,
      maxBytes: maxClientFrameBytes - utf8.encode(jsonEncode([configuration, summary])).length - 1024, conversationView: true);
    final oldest = data.lastOrNull?['seq'] as int?;
    return {
      'data': data,
      'next_cursor': oldest != null && db.select('SELECT 1 FROM events WHERE seq < ? LIMIT 1', [oldest]).isNotEmpty ? oldest : null,
      if (before == null) ...{
        'through': through,
        'configuration': configuration,
        'summary': summary,
        'reasoning': metadataValue('effective_reasoning'),
        'archived': metadataValue('archived_at') != null,
      },
    };
  }

  List<Json> modelContext({int maxBytes = maxContextBytes}) => readModelContext(db, maxBytes: maxBytes);

  void _validateHistoryAgent(Json params) {
    final name = params['agent_name'];
    if (name != null && name != '/root' && name != '.' && name != taskId) {
      throw ArgumentError(
        'This task has one agent; omit agent_name or use /root',
      );
    }
  }

  List<Json> listWindows(Json params) {
    _validateHistoryAgent(params);
    final limit = (params['limit'] as int? ?? 20).clamp(1, 100);
    final order = params['recent_first'] == false ? 'ASC' : 'DESC';
    return db
        .select(
          'SELECT window_id, count(*) AS item_count, min(seq) AS first_seq, max(seq) AS last_seq '
          'FROM events GROUP BY window_id ORDER BY first_seq $order LIMIT ?',
          [limit],
        )
        .map((row) => <String, dynamic>{...row})
        .toList();
  }

  Future<List<Json>> listItems(
    Json params, {
    CancellationToken? cancellation,
  }) => _historySelection(params, cancellation: cancellation);
  Future<List<Json>> searchContents(
    Json params, {
    CancellationToken? cancellation,
  }) {
    requiredString(params, 'query');
    return _historySelection(
      params,
      search: params['query'] as String,
      cancellation: cancellation,
    );
  }

  Future<List<Json>> _historySelection(
    Json params, {
    String? search,
    CancellationToken? cancellation,
  }) async {
    _validateHistoryAgent(params);
    final limit = (params['limit'] as int? ?? 20).clamp(1, 200);
    final chars = (params['max_chars_per_item'] as int? ?? 1500).clamp(
      1,
      16000,
    );
    final recent = params['recent_first'] != false;
    final order = recent ? 'DESC' : 'ASC';
    var cursor = recent ? lastSequence + 1 : 0;
    var remaining = 60000;
    final result = <Json>[];
    while (result.length < limit && remaining > 0) {
      cancellation?.throwIfCancelled();
      final page = db.select(
        'SELECT seq, id, window_id, type, created_at, data FROM events '
        'WHERE seq ${recent ? '<' : '>'} ? AND (? IS NULL OR window_id IS ?) ORDER BY seq $order LIMIT 100',
        [cursor, params['window_id'], params['window_id']],
      );
      if (page.isEmpty) break;
      for (final row in page) {
        cursor = row['seq'] as int;
        final item = _historyItem(row);
        final content = item.remove('content') as String;
        if (params['role'] != null && params['role'] != item['role']) continue;
        if (params['tool_name'] != null &&
            !(item['tool_names'] as List).contains(params['tool_name'])) {
          continue;
        }
        if (params['tool_namespace'] != null &&
            !(item['tool_namespaces'] as List).contains(
              params['tool_namespace'],
            )) {
          continue;
        }
        final offset = search == null ? 0 : content.indexOf(search);
        if (offset < 0) continue;
        final start = search == null
            ? 0
            : (offset - 200).clamp(0, content.length);
        final budget = chars.clamp(1, remaining);
        final snippet = content.substring(
          start,
          (start + budget).clamp(start, content.length),
        );
        item['truncated_content'] = snippet;
        item['offset_chars'] = start;
        item['total_chars'] = content.length;
        remaining -= utf8.encode(snippet).length + 300;
        result.add(item);
        if (result.length == limit || remaining <= 0) break;
      }
      await cancellableDelay(Duration.zero, cancellation);
    }
    return result;
  }

  Json readItem(Json params) {
    _validateHistoryAgent(params);
    final rows = db.select(
      'SELECT seq, id, window_id, type, created_at, data FROM events WHERE id IS ? AND window_id IS ?',
      [requiredString(params, 'item_id'), requiredString(params, 'window_id')],
    );
    if (rows.isEmpty) {
      throw StateError('History item not found in the requested window');
    }
    final item = _historyItem(rows.single);
    final text = item['content'] as String;
    final offset = params['offset_chars'] as int? ?? 0;
    if (offset < 0) throw ArgumentError('offset_chars must be nonnegative');
    final limit = (params['limit_chars'] as int? ?? 8000).clamp(1, 16000);
    final start = offset.clamp(0, text.length);
    item['content'] = text.substring(
      start,
      (start + limit).clamp(start, text.length),
    );
    item['offset_chars'] = start;
    item['total_chars'] = text.length;
    return item;
  }

  Json _historyItem(Map<String, Object?> row) {
    final data = jsonObject(jsonDecode(row['data'] as String));
    final names = <String>{}, namespaces = <String>{};
    String? role;
    final content = <String>[];
    void record(Json raw) {
      final item = ConversationItem.fromJson(raw);
      role ??= item.role ?? 'developer';
      for (final part in item.content) {
        switch (part['type']) {
          case 'text':
          case 'reasoning':
            content.add(part['text'] as String);
          case 'image':
            content.add('[Image: ${part['name']} (${part['mime_type']})]');
          case 'file':
            content.add(attachedFileText(part));
          case 'tool_call':
            names.add(part['name'] as String);
            namespaces.add(part['namespace'] as String? ?? '');
            content.add(part['input'] as String);
          case 'tool_result':
            if (part['name'] is String) names.add(part['name'] as String);
            namespaces.add(part['namespace'] as String? ?? 'functions');
            content.add(part['output'] as String);
        }
      }
      if (item.kind == 'configuration') content.add(jsonEncode(item.settings));
      if (item.kind == 'tools') {
        content.add(jsonEncode(item.tools.map((v) => v.toJson()).toList()));
      }
    }

    if (data['item'] is Map) record(jsonObject(data['item']));
    if (row['type'] == 'model.completed') {
      for (final raw in data['output'] as List) {
        record(jsonObject(raw));
      }
    }
    if ((row['type'] as String).startsWith('host_tool.')) {
      role = 'tool';
      if (data['name'] is String) {
        names.add(data['name'] as String);
        namespaces.add('tools');
      }
      content.add(jsonEncode(data));
    }
    if (row['type'] == 'context.compacted') {
      content.add(
        data['summary'] as String? ??
            'Context compacted. Original messages remain in earlier windows.',
      );
    }
    return {
      'item_id': row['id'],
      'window_id': row['window_id'],
      'seq': row['seq'],
      'created_at': row['created_at'],
      'role': role ?? 'system',
      'type': row['type'],
      'tool_names': names.toList(),
      'tool_namespaces': namespaces.toList(),
      'content': content.join('\n'),
    };
  }

  Future<void> fork(
    String childId, {
    int? through,
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    validateTaskId(childId);
    final cutoff = through ?? lastSequence;
    final boundary = db.select('SELECT type FROM events WHERE seq IS ?', [
      cutoff,
    ]);
    if (boundary.isEmpty ||
        ![
          'turn.completed',
          'turn.failed',
          'turn.cancelled',
          'task.forked',
          'task.imported',
          'task.archived',
          'task.unarchived',
        ].contains(boundary.first['type'])) {
      throw StateError('Forks require a terminal turn boundary');
    }
    if (Directory('$directory/tasks/$childId').existsSync()) {
      throw StateError('Destination exists');
    }
    final stage = Directory('$directory/staging/${newId()}')
      ..createSync(recursive: true);
    final child = TaskStore(stage.path, childId);
    try {
      var after = 0;
      while (after < cutoff) {
        cancellation?.throwIfCancelled();
        final page = history(after: after, through: cutoff);
        child._copy(page);
        after = page.last['seq'] as int;
        await cancellableDelay(Duration.zero, cancellation);
      }
      child._rebuildMetadata();
      child.append(
        'task.forked',
        {'parent_id': taskId, 'parent_seq': cutoff},
        metadata: {'status': 'idle'},
      );
      child.close();
      cancellation?.throwIfCancelled();
      Directory('${stage.path}/tasks/$childId')
          .renameSync('$directory/tasks/$childId');
    } finally {
      child.close();
      stage.deleteSync(recursive: true);
    }
  }

  void _copy(List<Json> events) {
    db.execute('BEGIN');
    try {
      for (final event in events) {
        db.execute(
          'INSERT INTO events(seq, id, window_id, type, created_at, data) VALUES (?, ?, ?, ?, ?, ?)',
          [
            event['seq'],
            event['id'],
            event['window_id'],
            event['type'],
            event['created_at'],
            jsonEncode(event['data']),
          ],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    _projectConversation(events);
  }

  void _rebuildMetadata() {
    for (final pair in [
      ('task.created', 'config', null),
      ('tool.completed', 'values', 'values'),
      ('configuration.updated', 'effective_reasoning', 'effort'),
      ('environment.updated', 'current_cwd', 'cwd'),
      ('agents.updated', 'agents_snapshot', 'snapshot'),
      ('mcp.updated', 'mcp_snapshot', 'snapshot'),
      ('client_tools.updated', 'client_tools_snapshot', 'snapshot'),
    ]) {
      final rows = db.select(
        'SELECT data FROM events WHERE type IS ? AND (? IS NULL OR json_type(data, ?) IS NOT NULL) ORDER BY seq DESC LIMIT 1',
        [pair.$1, pair.$3, '\$.${pair.$3}'],
      );
      if (rows.isEmpty) continue;
      final data = jsonObject(jsonDecode(rows.first['data'] as String));
      final value = pair.$3 == null ? data : data[pair.$3];
      if (value != null) {
        db.execute(
          'INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)',
          [pair.$2, jsonEncode(value)],
        );
      }
    }
    final skills = db.select(
      "SELECT data FROM events WHERE type IN ('skills.updated', 'context.compacted') "
      "AND json_type(data, '\$.skills_state') IS NOT NULL ORDER BY seq DESC LIMIT 1",
    );
    if (skills.isNotEmpty) {
      final data = jsonObject(jsonDecode(skills.single['data'] as String));
      db.execute('INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)',
        ['skills_state', jsonEncode(data['skills_state'])]);
    }
    final latest = db.select(
      'SELECT window_id FROM events ORDER BY seq DESC LIMIT 1',
    );
    if (latest.isNotEmpty) {
      db.execute('INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)', [
        'current_window',
        jsonEncode(latest.single['window_id']),
      ]);
    }
  }

  Future<void> exportTo(
    String destination, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (metadata('status') == 'running') {
      throw StateError('Export requires an idle task');
    }
    if (File(destination).existsSync()) {
      throw StateError('Export destination exists');
    }
    final temporary = File('$destination.partial-${newId()}');
    temporary.parent.createSync(recursive: true);
    final sink = temporary.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var count = 0;
    void write(Json event) {
      final bytes = utf8.encode('${jsonEncode(event)}\n');
      hasher.add(bytes);
      sink.add(bytes);
    }

    try {
      final cutoff = lastSequence;
      write({
        'format': 'agent.history',
        'version': 2,
        'source_task': taskId,
        'through': cutoff,
      });
      var after = 0;
      while (after < cutoff) {
        cancellation?.throwIfCancelled();
        final page = history(after: after, through: cutoff);
        for (final event in page) {
          write(event);
          count++;
        }
        after = page.last['seq'] as int;
        await sink.flush();
        cancellation?.throwIfCancelled();
      }
      hasher.close();
      sink.write(
        '${jsonEncode({'sha256': digest.value.toString(), 'records': count})}\n',
      );
      await sink.flush();
      await sink.close();
      cancellation?.throwIfCancelled();
      await temporary.rename(destination);
    } catch (_) {
      await sink.close();
      if (temporary.existsSync()) temporary.deleteSync();
      rethrow;
    }
  }

  static Future<String> importFrom(
    String directory,
    String source, {
    String? operationId,
    required Future<String> Function(Json config) newTaskId,
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    // The server resolves duplicate operations through existing task owners.
    // This owner writes only the new, unpublished database.
    if (operationId != null) validateTaskId(operationId);
    final stage = Directory('$directory/staging/${newId()}')
      ..createSync(recursive: true);
    const stagingId = 'import';
    final store = TaskStore(stage.path, stagingId);
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var count = 0;
    Json? header, footer;
    final batch = <Json>[];
    try {
      final input = ownStream(
        File(source).openRead(),
        cancellation ?? CancellationToken(),
      );
      try {
        await for (final line in boundedLines(
          input.stream,
          maxBytes: maxContextBytes + maxFrameBytes,
        )) {
          cancellation?.throwIfCancelled();
          final item = jsonObject(jsonDecode(line));
          if (header == null) {
            if (item['format'] != 'agent.history' ||
                item['version'] != 2) {
              throw const FormatException('Unsupported history format');
            }
            header = item;
          } else if (item.containsKey('sha256')) {
            if (footer != null) throw const FormatException('Duplicate footer');
            footer = item;
            continue;
          } else {
            if (footer != null ||
                item['seq'] != count + 1 ||
                item['type'] is! String ||
                item['created_at'] is! String ||
                item['data'] is! Map) {
              throw const FormatException('Invalid history record');
            }
            count++;
            requiredString(item, 'id');
            requiredString(item, 'window_id');
            batch.add(item);
            if (batch.length == 100) {
              store._copy(batch);
              batch.clear();
            }
          }
          hasher.add(utf8.encode('$line\n'));
        }
      } finally {
        await input.close();
      }
      cancellation?.throwIfCancelled();
      hasher.close();
      if (footer == null ||
          footer['records'] != count ||
          footer['sha256'] != digest.value.toString() ||
          header?['through'] != count) {
        throw const FormatException('Incomplete history or checksum mismatch');
      }
      store._copy(batch);
      store._rebuildMetadata();
      final id = await newTaskId(jsonObject(store.metadata('config') ?? {}));
      validateTaskId(id);
      if (Directory('$directory/tasks/$id').existsSync()) throw StateError('Destination exists');
      store.append(
        'task.imported',
        {'source_task': header!['source_task']},
        metadata: {'status': 'idle', 'import_operation': ?operationId},
      );
      store.close();
      Directory('$directory/tasks').createSync(recursive: true);
      cancellation?.throwIfCancelled();
      Directory('${stage.path}/tasks/$stagingId').renameSync('$directory/tasks/$id');
      return id;
    } finally {
      store.close();
      if (stage.existsSync()) stage.deleteSync(recursive: true);
    }
  }

  bool _closed = false;
  void close() {
    if (!_closed) {
      _closed = true;
      db.close();
    }
  }
}

/// Display history excludes execution checkpoints. Canonical history.page,
/// recall, forks and exports retain every field in the original event.
Json _conversationEvent(Json event) {
  final data = jsonObject(event['data']);
  final display = switch (event['type']) {
    'model.completed' => <String, dynamic>{
      'usage': data['usage'],
      'output': [
        for (final raw in data['output'] as List? ?? []) {
          'content': [
            for (final part in raw['content'] as List? ?? [])
              if ((part['type'] == 'text' || part['type'] == 'reasoning') && part['text'] is String)
                {'type': part['type'], 'text': part['text']},
          ],
        },
      ],
    },
    'tool.completed' => <String, dynamic>{'item': data['item']},
    'context.compacted' => <String, dynamic>{'summary': data['summary']},
    'task.created' => <String, dynamic>{
      for (final key in ['provider', 'model', 'reasoning', 'reasoning_updates'])
        if (data.containsKey(key)) key: data[key],
      'provider_settings': {
        for (final key in ['reasoning', 'context_limit'])
          if ((data['provider_settings'] as Map?)?.containsKey(key) == true)
            key: data['provider_settings'][key],
      },
    },
    'agents.updated' || 'skills.updated' || 'mcp.updated' ||
    'environment.updated' || 'instructions.updated' || 'tools.updated' => <String, dynamic>{},
    _ => data,
  };
  return {...event, 'data': display};
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
