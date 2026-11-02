import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';

/// The model's current window: replacement history at the last checkpoint,
/// followed by its committed suffix. Used only when restoring an agent.
List<Json> readModelContext(Database db, {int maxBytes = maxContextBytes}) {
  final checkpoint = db.select(
    "SELECT seq, data FROM events WHERE type = 'context.compacted' ORDER BY seq DESC LIMIT 1",
  );
  final items = <Json>[];
  var bytes = 0;
  void add(String type, Json data) {
    for (final value in modelContextItems(type, data)) {
      final item = value.toJson();
      bytes += utf8.encode(jsonEncode(item)).length;
      if (bytes > maxBytes) {
        throw StateError('Active context exceeds the byte budget; compact before continuing.');
      }
      items.add(item);
    }
  }
  final after = checkpoint.isEmpty ? 0 : checkpoint.single['seq'] as int;
  if (checkpoint.isNotEmpty) {
    add('context.compacted', jsonObject(jsonDecode(checkpoint.single['data'] as String)));
  }
  final query = db.prepare('''
    SELECT type, data FROM events WHERE seq > ? AND type IN (
      'input.committed', 'configuration.updated', 'instructions.updated',
      'environment.updated', 'tools.updated', 'agents.updated', 'mcp.updated',
      'client_tools.updated', 'skills.updated', 'model.completed', 'tool.completed'
    ) ORDER BY seq
  ''');
  try {
    final rows = query.selectCursor([after]);
    while (rows.moveNext()) {
      add(rows.current['type'] as String, jsonObject(jsonDecode(rows.current['data'] as String)));
    }
  } finally { query.close(); }
  return items;
}
