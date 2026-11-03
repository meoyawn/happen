/// Chrome flow arrows bind to synchronous slices on their source and target
/// threads. Async spans alone cannot anchor them. Zero-duration slices keep
/// these transport endpoints visible without inventing execution time.
Iterable<Map<String, dynamic>> traceExportEvents(Iterable<Map> events) sync* {
  for (final event in events) {
    final phase = event['ph'];
    if (phase == 's' || phase == 'f') {
      yield {
        'name': '${event['name']}.${phase == 's' ? 'send' : 'receive'}',
        'cat': event['cat'], 'pid': event['pid'], 'tid': event['tid'],
        'ts': event['ts'], 'ph': 'X', 'dur': 0, 'args': event['args'],
      };
    }
    yield Map<String, dynamic>.from(event);
  }
}
