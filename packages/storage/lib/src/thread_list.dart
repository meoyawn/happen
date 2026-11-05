import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:telemetry/telemetry.dart';

import 'session_reader.dart';

/// Native thread inventory. There is no global database or second projection:
/// each reader opens the owning session SQLite read-only.
Future<Json> listThreads(String directory, Json params, {required CancellationToken cancellation}) {
  cancellation.throwIfCancelled();
  final carrier = currentTrace?.carrier();
  return CancellableIsolate.run(() => withTrace(traceContextFrom(carrier, service: 'storage'), () async {
    final filter = params['cursor'] == null ? ({...params}..remove('limit')) :
      jsonObject(jsonDecode(utf8.decode(base64Url.decode(params['cursor'] as String))));
    final direction = filter['sortDirection'] as String? ?? 'desc';
    if (!{'asc', 'desc'}.contains(direction)) throw const FormatException('Invalid thread order');
    final limit = (params['limit'] as int? ?? 100).clamp(1, 500);
    final folder = Directory('$directory/tasks'), threads = <Json>[];
    if (!folder.existsSync()) return {'data': <Json>[], 'nextCursor': null};
    String key(String path) => Directory(path).absolute.uri.normalizePath().toString();
    for (final entry in folder.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final id = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      try { validateTaskId(id); } on FormatException { continue; }
      final path = '${entry.path}/history.sqlite';
      if (!File(path).existsSync()) continue;
      try {
        final page = await withReadOnlySnapshot<Json?>(path, (db) =>
          (storedMetadata(db, 'archived_at') != null) != (filter['archived'] == true) ? null
            : readStoredSession(db, 'thread/read', {}, directory: directory, id: id));
        if (page == null) continue;
        final info = jsonObject(page['thread']);
        if (filter['cwd'] is String && key(info['cwd'] as String) != key(filter['cwd'] as String)) continue;
        if (filter['modelProviders'] is List && !(filter['modelProviders'] as List).contains(info['modelProvider'])) continue;
        if (filter.containsKey('parentThreadId') && info['parentThreadId'] != filter['parentThreadId']) continue;
        if (filter['searchTerm'] is String && !'${info['name'] ?? ''} ${info['preview']}'.toLowerCase().contains((filter['searchTerm'] as String).toLowerCase())) continue;
        threads.add(info);
      } on SqliteException catch (error) {
        if (error.resultCode == 5) rethrow;
        // A broken neighbour must not hide healthy sessions.
      } on FormatException {
        // Invalid lineage is local to the affected thread.
      }
    }
    final sortKey = filter['sortKey'] == 'created_at' ? 'createdAt' : 'updatedAt';
    int compare(Json a, Json b) {
      final time = (a[sortKey] as int).compareTo(b[sortKey] as int);
      final result = time == 0 ? (a['id'] as String).compareTo(b['id'] as String) : time;
      return direction == 'asc' ? result : -result;
    }
    threads.sort(compare);
    final anchor = filter['anchor'];
    final values = anchor == null ? threads : threads.where((thread) => compare(thread, jsonObject(anchor)) > 0).toList();
    final page = values.take(limit).toList();
    return {'data': page, 'nextCursor': values.length <= limit ? null : base64Url.encode(utf8.encode(jsonEncode({
      ...filter, 'anchor': {'id': page.last['id'], sortKey: page.last[sortKey]},
    })))};
  }), cancellation);
}
