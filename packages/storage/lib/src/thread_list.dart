import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import 'session_reader.dart';

/// Codex StateRuntime-style keyset listing over the shared metadata catalog.
/// Histories are opened only for a requested thread, never to render a list.
Future<Json> listThreads(String directory, Json params, {required CancellationToken cancellation}) {
  cancellation.throwIfCancelled();
  final carrier = currentTrace?.carrier();
  return CancellableIsolate.run(() => withTrace(traceContextFrom(carrier, service: 'storage'), () =>
    withReadOnlySnapshot('$directory/server.sqlite', (db) => _catalogPage(db, params))), cancellation);
}

Json _catalogPage(TracedDatabase db, Json params) {
  final filter = params['cursor'] == null ? ({...params}..remove('limit')) :
    jsonObject(jsonDecode(utf8.decode(base64Url.decode(params['cursor'] as String))));
  final direction = filter['sortDirection'] as String? ?? 'desc';
  if (!{'asc', 'desc'}.contains(direction)) throw const FormatException('Invalid thread order');
  final limit = (params['limit'] as int? ?? 100).clamp(1, 500);
  final conditions = <String>['archived IS ?'], values = <Object?>[filter['archived'] == true ? 1 : 0];
  if (filter['cwd'] case final String cwd) {
    conditions.add('cwd IS ?'); values.add(Directory(cwd).absolute.uri.normalizePath().toString());
  }
  if (filter['modelProviders'] case final List providers) {
    conditions.add(providers.isEmpty ? '0' : 'model_provider IN (${List.filled(providers.length, '?').join(',')})');
    values.addAll(providers);
  }
  if (filter.containsKey('parentThreadId')) {
    conditions.add("json_extract(data,'\$.parentThreadId') IS ?"); values.add(filter['parentThreadId']);
  }
  if (filter['searchTerm'] case final String search) {
    conditions.add('instr(search_text,?) > 0'); values.add(search.toLowerCase());
  }
  final created = filter['sortKey'] == 'created_at', column = created ? 'created_at' : 'updated_at';
  final sortKey = created ? 'createdAt' : 'updatedAt';
  if (filter['anchor'] case final Map anchor) {
    final comparison = direction == 'asc' ? '>' : '<';
    conditions.add('($column $comparison ? OR ($column IS ? AND id $comparison ?))');
    values.addAll([anchor[sortKey], anchor[sortKey], anchor['id']]);
  }
  final rows = db.select('SELECT data FROM threads WHERE ${conditions.join(' AND ')} '
    'ORDER BY $column $direction,id $direction LIMIT ?', [...values, limit + 1]);
  final threads = <Json>[];
  for (final row in rows) {
    try {
      final thread = jsonObject(jsonDecode(row['data'] as String));
      if (thread['id'] is String && thread['createdAt'] is int && thread['updatedAt'] is int) threads.add(thread);
    } on FormatException { /* One invalid metadata row must not discard its neighbors. */ }
  }
  final page = threads.take(limit).toList();
  return {'data': page, 'nextCursor': threads.length <= limit || page.isEmpty ? null
    : base64Url.encode(utf8.encode(jsonEncode({...filter, 'anchor': {'id': page.last['id'], sortKey: page.last[sortKey]}})))};
}
