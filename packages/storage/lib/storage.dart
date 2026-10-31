import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';

export 'src/owner.dart' show startStore, importHistory;

typedef LegacyRecordDecoder = ConversationItem Function(
  Json wire, {
  String? id,
});

/// Access this object only from its dedicated SQLite owner isolate.
class TaskStore {
  TaskStore(
    this.directory,
    this.taskId, {
    bool create = true,
    this.legacyDecoder,
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
    db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        seq INTEGER PRIMARY KEY, type TEXT NOT NULL,
        created_at TEXT NOT NULL, data TEXT NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS events_type ON events(type, seq);
      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY, value TEXT NOT NULL
      ) STRICT;
    ''');
    final columns = db
        .select('PRAGMA table_info(events)')
        .map((row) => row['name'])
        .toSet();
    if (!columns.contains('id')) {
      db.execute('ALTER TABLE events ADD COLUMN id TEXT');
    }
    if (!columns.contains('window_id')) {
      db.execute('ALTER TABLE events ADD COLUMN window_id TEXT');
    }
    db.execute('UPDATE events SET id = ? || seq WHERE id IS NULL', [
      '$taskId:',
    ]);
    db.execute('UPDATE events SET window_id = ? WHERE window_id IS NULL', [
      '$taskId:0',
    ]);
    db.execute('CREATE UNIQUE INDEX IF NOT EXISTS events_id ON events(id)');
    db.execute(
      'CREATE INDEX IF NOT EXISTS events_window ON events(window_id, seq)',
    );
    db.execute('PRAGMA user_version = 2');
  }
  final String directory, taskId;
  final LegacyRecordDecoder? legacyDecoder;
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
    db.execute('BEGIN');
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final committed = <Json>[];
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
        committed.add({
          'seq': db.lastInsertRowId,
          'id': id,
          'window_id': window,
          'type': event['type'],
          'created_at': now,
          'data': event['data'],
        });
      }
      for (final entry in {...metadata, 'current_window': window}.entries) {
        db.execute(
          'INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [entry.key, jsonEncode(entry.value)],
        );
      }
      db.execute('COMMIT');
      return committed;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
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

  List<Json> history({int after = 0, int limit = 100, int? through}) {
    if (limit < 1 || limit > 500) {
      throw const FormatException('History limit must be 1..500');
    }
    final query = db.prepare(
      'SELECT seq, id, window_id, type, created_at, data FROM events WHERE seq > ? AND seq <= ? ORDER BY seq LIMIT ?',
    );
    try {
      final rows = query.selectCursor([after, through ?? lastSequence, limit]);
      final result = <Json>[];
      var bytes = 0;
      while (rows.moveNext()) {
        final row = rows.current;
        final encoded = row['data'] as String;
        bytes += utf8.encode(encoded).length + 512;
        // A compaction checkpoint may itself fill a page. Never split a record.
        if (result.isNotEmpty && bytes > maxClientFrameBytes) break;
        result.add({
            'seq': row['seq'],
            'id': row['id'],
            'window_id': row['window_id'],
            'type': row['type'],
            'created_at': row['created_at'],
            'data': jsonDecode(encoded),
        });
      }
      return result;
    } finally {
      query.close();
    }
  }

  List<Json> modelContext({int maxBytes = maxContextBytes}) {
    final compacted = db.select(
      "SELECT seq, id, data FROM events WHERE type IS 'context.compacted' ORDER BY seq DESC LIMIT 1",
    );
    var after = 0, bytes = 0;
    final result = <Json>[];
    Json decode(Json item, String id) => item['version'] == 1
        ? ConversationItem.fromJson(item).toJson()
        : (legacyDecoder ??
                  (throw const FormatException(
                    'Legacy GPT history needs its provider decoder',
                  )))(item, id: id)
              .toJson();
    if (compacted.isNotEmpty) {
      after = compacted.first['seq'] as int;
      final data = jsonObject(jsonDecode(compacted.first['data'] as String));
      var index = 0;
      result.addAll(
        (data['input'] as List).map(
          (raw) =>
              decode(jsonObject(raw), '${compacted.first['id']}:${index++}'),
        ),
      );
      bytes += (compacted.first['data'] as String).length;
      if (bytes > maxBytes) {
        throw StateError('Compacted context exceeds the byte budget');
      }
    }
    while (true) {
      final page = history(after: after);
      if (page.isEmpty) break;
      for (final event in page) {
        after = event['seq'] as int;
        final data = jsonObject(event['data']);
        final items = switch (event['type']) {
          'input.committed' ||
          'configuration.updated' ||
          'instructions.updated' ||
          'environment.updated' ||
          'tools.updated' ||
          'agents.updated' ||
          'mcp.updated' ||
          'client_tools.updated' => [jsonObject(data['item'])],
          'skills.updated' => [if (data['item'] != null) jsonObject(data['item'])],
          'model.completed' =>
            (data['output'] as List).map(jsonObject).toList(),
          'tool.completed' => [jsonObject(data['item'])],
          _ => <Json>[],
        };
        var index = 0;
        for (final raw in items) {
          final item = decode(raw, '${event['id']}:${index++}');
          bytes += utf8.encode(jsonEncode(item)).length;
          if (bytes > maxBytes) {
            throw StateError(
              'Active context exceeds the byte budget; compact before continuing.',
            );
          }
          result.add(item);
        }
      }
    }
    return result;
  }

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
      final ConversationItem item;
      if (raw['version'] == 1) {
        item = ConversationItem.fromJson(raw);
      } else if (legacyDecoder != null) {
        item = legacyDecoder!(raw);
      } else {
        content.add(jsonEncode(raw));
        return;
      }
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
    final child = TaskStore(stage.path, childId, legacyDecoder: legacyDecoder);
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
  }

  void _rebuildMetadata() {
    for (final pair in [
      ('task.created', 'config', null),
      ('task.configuration_migrated', 'config', null),
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
    if (operationId != null) {
      validateTaskId(operationId);
      final tasks = Directory('$directory/tasks');
      if (tasks.existsSync()) {
        for (final entry in tasks.listSync(followLinks: false).whereType<Directory>()) {
          cancellation?.throwIfCancelled();
          final id = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
          try { validateTaskId(id); } on FormatException { continue; }
          if (!File('${entry.path}/history.sqlite').existsSync()) continue;
          final existing = sqlite3.open('${entry.path}/history.sqlite', mode: OpenMode.readOnly);
          try {
            final rows = existing.select("SELECT value FROM metadata WHERE key IS 'import_operation'");
            if (rows.isNotEmpty && jsonDecode(rows.single['value'] as String) == operationId) return id;
          } finally {
            existing.close();
          }
        }
      }
    }
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
                ![1, 2].contains(item['version'])) {
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
            if (header['version'] == 1) {
              item['id'] = '${header['source_task']}:$count';
              item['window_id'] = '${header['source_task']}:0';
            }
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

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
