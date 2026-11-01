import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';

/// The model's current window: replacement history at the last checkpoint,
/// followed by its committed suffix. Both inference and inspection use this fold.
List<Json> readModelContext(Database db, {int? through, int maxBytes = maxContextBytes}) {
  final fence = through ?? db.select('SELECT coalesce(max(seq), 0) AS seq FROM events').single['seq'] as int;
  final checkpoint = db.select(
    "SELECT seq, data FROM events WHERE type = 'context.compacted' AND seq <= ? ORDER BY seq DESC LIMIT 1",
    [fence],
  );
  final items = <Json>[];
  var bytes = 0;
  void add(Object? raw) {
    final item = ConversationItem.fromJson(jsonObject(raw)).toJson();
    bytes += utf8.encode(jsonEncode(item)).length;
    if (bytes > maxBytes) {
      throw StateError('Active context exceeds the byte budget; compact before continuing.');
    }
    items.add(item);
  }
  final after = checkpoint.isEmpty ? 0 : checkpoint.single['seq'] as int;
  if (checkpoint.isNotEmpty) {
    for (final item in jsonObject(jsonDecode(checkpoint.single['data'] as String))['input'] as List) { add(item); }
  }
  final query = db.prepare('''
    SELECT type, data FROM events WHERE seq > ? AND seq <= ? AND type IN (
      'input.committed', 'configuration.updated', 'instructions.updated',
      'environment.updated', 'tools.updated', 'agents.updated', 'mcp.updated',
      'client_tools.updated', 'skills.updated', 'model.completed', 'tool.completed'
    ) ORDER BY seq
  ''');
  try {
    final rows = query.selectCursor([after, fence]);
    while (rows.moveNext()) {
      final row = rows.current, data = jsonObject(jsonDecode(rows.current['data'] as String));
      if (row['type'] == 'model.completed') {
        for (final item in data['output'] as List) { add(item); }
      } else if (data['item'] != null) {
        add(data['item']);
      }
    }
  } finally { query.close(); }
  return items;
}
