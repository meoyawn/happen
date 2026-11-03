part of '../storage.dart';

extension ToolRuntimeHistory on TaskStore {
  /// Bind restored history to its live tool owner before the model can reuse
  /// process or cell handles from a previous execution environment.
  List<Json> startToolRuntime(String id) {
    final input = modelContext().map((item) => ConversationItem.fromJson(item)).toList();
    final completed = input.expand((item) => item.content)
      .where((part) => part['type'] == 'tool_result').map((part) => part['call_id']).toSet();
    final events = <Json>[
      for (final call in input.expand((item) => item.calls))
        if (!completed.contains(call.id)) {'type': 'tool.completed', 'data': {
          'item': ConversationItem.toolResult(call,
            'Interrupted before a durable result. Side effects may have occurred; inspect state before retrying.',
            isError: true).toJson(),
        }},
    ];
    final previous = db.select(
      "SELECT json_extract(data, '\$.id') AS id FROM events "
      "WHERE type IS 'tool_runtime.started' ORDER BY seq DESC LIMIT 1",
    ).firstOrNull;
    if (previous?['id'] == id) return events.isEmpty ? [] : appendBatch(events);
    final restarted = previous != null || input.isNotEmpty;
    return appendBatch([...events,
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
