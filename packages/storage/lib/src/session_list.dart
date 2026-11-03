import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:telemetry/telemetry.dart';

String _directoryKey(String path) => Directory(path).absolute.uri.normalizePath().toString();

Json? _sessionInfo(String path, String id) {
  final db = openTracedDatabase(path, mode: OpenMode.readOnly);
  try {
    db.execute('PRAGMA query_only = ON');
    db.execute('BEGIN');
    final configuration = db.select("SELECT json_extract(value, '\$.cwd') AS directory, "
      "json_extract(value, '\$.provider') AS provider, json_extract(value, '\$.model') AS model "
      "FROM metadata WHERE key IS 'config'").firstOrNull;
    final directory = configuration?['directory'] as String?;
    if (directory == null || directory.isEmpty) return null;
    Object? metadata(String key) {
      final row = db.select('SELECT value FROM metadata WHERE key IS ?', [key]).firstOrNull;
      return row == null ? null : jsonDecode(row['value'] as String);
    }
    var title = metadata('title') as String?;
    if (title == null || title.trim().isEmpty) {
      final input = db.select("SELECT coalesce(json_extract(data, '\$.item.content[0].text'), "
        "json_extract(data, '\$.item.content[0].name')) AS title FROM events "
        "WHERE type IS 'input.committed' ORDER BY seq LIMIT 1").firstOrNull;
      title = input?['title'] as String?;
    }
    title = title?.trim().split('\n').first;
    if (title == null || title.isEmpty) title = 'New session';
    if (title.length > 72) title = '${title.substring(0, 72)}…';
    int timestamp(Object? value) => DateTime.parse(value as String).millisecondsSinceEpoch;
    final first = db.select('SELECT created_at FROM events ORDER BY seq LIMIT 1').firstOrNull;
    if (first == null) return null;
    final last = db.select('SELECT created_at FROM events ORDER BY seq DESC LIMIT 1').single;
    final archived = metadata('archived_at');
    final started = db.select("SELECT created_at FROM events WHERE type IS 'turn.started' ORDER BY seq DESC LIMIT 1").firstOrNull;
    final ended = db.select("SELECT type, created_at FROM events WHERE type IN "
      "('turn.completed', 'turn.failed', 'turn.cancelled') ORDER BY seq DESC LIMIT 1").firstOrNull;
    final parent = db.select("SELECT json_extract(data, '\$.parent_id') AS id FROM events "
      "WHERE type IS 'task.forked' ORDER BY seq DESC LIMIT 1").firstOrNull?['id'];
    return {
      'id': id, 'title': title, 'location': {'directory': directory},
      'parentID': ?parent,
      'model': {'providerID': configuration!['provider'], 'id': configuration['model']},
      if (ended != null) 'outcome': switch (ended['type']) {
        'turn.completed' => 'succeeded', 'turn.failed' => 'failed', _ => 'interrupted',
      },
      'time': {'created': timestamp(first['created_at']), 'updated': timestamp(last['created_at']),
        if (started != null) 'busy': timestamp(started['created_at']),
        if (ended != null) 'idle': timestamp(ended['created_at']),
        if (archived != null) 'archived': timestamp(archived)},
    };
  } finally { db.close(); }
}

/// The durable session inventory, independent of live agent owners and desktop
/// caches. Reading metadata never projects history or resumes interrupted work.
Future<Json> listSessions(String directory, Json params, {required CancellationToken cancellation}) {
  cancellation.throwIfCancelled();
  final carrier = currentTrace?.carrier();
  return CancellableIsolate.run(() => withTrace(traceContextFrom(carrier, service: 'storage'), () {
    final Json filter;
    try {
      filter = params['cursor'] == null ? ({...params}..remove('limit'))
        : jsonObject(jsonDecode(utf8.decode(base64Url.decode(params['cursor'] as String))));
      if (filter['anchor'] != null) {
        final anchor = jsonObject(filter['anchor']);
        requiredString(anchor, 'id');
        if (anchor['time'] is! int || !{'previous', 'next'}.contains(anchor['direction'])) {
          throw const FormatException('Invalid session cursor');
        }
      }
    } catch (_) { throw const FormatException('Invalid session cursor'); }
    final limit = (params['limit'] as int? ?? 50).clamp(1, 5000);
    final order = filter['order'] as String? ?? 'desc';
    if (!{'asc', 'desc'}.contains(order)) throw const FormatException('Invalid session order');
    final folder = Directory('$directory/tasks');
    final sessions = <Json>[];
    if (!folder.existsSync()) return {'data': <Json>[], 'cursor': <String, dynamic>{}};
    for (final entry in folder.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final id = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      try { validateTaskId(id); } on FormatException { continue; }
      final path = '${entry.path}/history.sqlite';
      if (!File(path).existsSync()) continue;
      final Json? info;
      try { info = _sessionInfo(path, id); }
      on SqliteException { continue; } // A broken transcript must not hide its neighbours.
      on FormatException { continue; }
      if (info == null) continue;
      if (filter['directory'] case final String selected) {
        if (_directoryKey(info['location']['directory'] as String) != _directoryKey(selected)) continue;
      }
      if (filter.containsKey('parentID') && info['parentID'] != filter['parentID']) continue;
      if (filter['archived'] case final bool archived) {
        if ((info['time']['archived'] != null) != archived) continue;
      }
      if (filter['search'] case final String search) {
        if (!(info['title'] as String).toLowerCase().contains(search.toLowerCase())) continue;
      }
      sessions.add(info);
    }
    int compare(Json a, Json b) {
      final time = (a['time']['updated'] as int).compareTo(b['time']['updated'] as int);
      final result = time != 0 ? time : (a['id'] as String).compareTo(b['id'] as String);
      return order == 'asc' ? result : -result;
    }
    sessions.sort(compare);
    final anchor = filter['anchor'] as Json?;
    final previous = anchor?['direction'] == 'previous';
    final matching = anchor == null ? sessions : sessions.where((info) {
      final relation = compare(info, {'id': anchor['id'], 'time': {'updated': anchor['time']}});
      return previous ? relation < 0 : relation > 0;
    }).toList();
    final page = previous ? matching.skip((matching.length - limit).clamp(0, matching.length)).toList()
      : matching.take(limit).toList();
    String cursor(Json info, String direction) => base64Url.encode(utf8.encode(jsonEncode({
      ...filter, 'anchor': {'id': info['id'], 'time': info['time']['updated'], 'direction': direction},
    })));
    return {'data': page, 'cursor': {
      if (page.isNotEmpty) 'previous': cursor(page.first, 'previous'),
      if (page.isNotEmpty) 'next': cursor(page.last, 'next'),
    }};
  }), cancellation);
}
