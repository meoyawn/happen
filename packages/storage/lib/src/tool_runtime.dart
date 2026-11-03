part of '../storage.dart';

extension ToolRuntimeHistory on TaskStore {
  /// Bind restored history to its live tool owner before the model can reuse
  /// process or cell handles from a previous execution environment.
  List<Json> startToolRuntime(String id) {
    final previous = db.select(
      "SELECT json_extract(data, '\$.id') AS id FROM events "
      "WHERE type IS 'tool_runtime.started' ORDER BY seq DESC LIMIT 1",
    ).firstOrNull;
    if (previous?['id'] == id) return [];
    final restarted = previous != null || db.select(
      "SELECT 1 FROM events WHERE type IN ('model.completed', 'context.compacted') LIMIT 1",
    ).isNotEmpty;
    return appendBatch([
      {'type': 'tool_runtime.started', 'data': {'id': id}},
      if (restarted) {'type': 'input.committed', 'data': {
        'item': ConversationItem(role: 'user', content: [{
          'type': 'text',
          'text': 'The tool runtime was restarted. Command sessions, background commands, and running code cells '
            'from the previous runtime are no longer available. Do not reuse earlier session or cell IDs. '
            'Completed tool results and stored values remain available. Continue from the recorded results, '
            'inspect the effects of interrupted commands, and start a new command only when needed.',
        }], native: {'harness': {'context': 'tool_notification', 'reason': 'tool_runtime_restarted'}}).toJson(),
      }},
    ]);
  }
}
