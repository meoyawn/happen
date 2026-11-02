part of '../storage.dart';

/// OpenCode's generic JSON KV contract, in the existing session database.
/// Namespaces and domain behavior belong to callers, not the storage package.
Object? _keyValue(TaskStore store, String method, Json arguments) {
  String string(String name, [String? fallback]) {
    final value = arguments[name] ?? fallback;
    if (value is! String) throw FormatException('$name must be a string');
    return value;
  }
  switch (method) {
    case 'get':
      final rows = store.db.select('SELECT value FROM kv WHERE key IS ?', [string('key')]);
      return rows.isEmpty ? null : jsonDecode(rows.single['value'] as String);
    case 'set':
      if (!arguments.containsKey('value')) throw const FormatException('value is required');
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      store.db.execute('''INSERT INTO kv(key, value, time_created, time_updated) VALUES (?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, time_updated = excluded.time_updated''',
        [string('key'), jsonEncode(arguments['value']), now, now]);
      return null;
    case 'remove':
      store.db.execute('DELETE FROM kv WHERE key IS ?', [string('key')]);
      return null;
    case 'scan':
      final prefix = string('prefix', '');
      final after = arguments['after'] == null ? null : string('after');
      final requested = arguments['limit'] ?? 100;
      if (requested is! num) throw const FormatException('limit must be a number');
      final limit = requested.isNaN ? 100 : requested.clamp(1, 1000).floor();
      final points = prefix.runes.toList();
      final index = points.lastIndexWhere((point) => point < 0x10ffff);
      final end = index < 0 ? null : String.fromCharCodes([...points.take(index), points[index] + 1]);
      final clauses = ['key >= ?', if (end != null) 'key < ?', if (after != null) 'key > ?'];
      final rows = store.db.select('SELECT key, value FROM kv WHERE ${clauses.join(' AND ')} ORDER BY key LIMIT ?',
        [prefix, ?end, ?after, limit + 1]);
      final entries = [for (final row in rows.take(limit)) {'key': row['key'], 'value': jsonDecode(row['value'] as String)}];
      return {'entries': entries, if (rows.length > limit) 'next': entries.last['key']};
    default: throw StateError('Unknown key/value operation: $method');
  }
}
