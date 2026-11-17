import 'package:cancellation_token/cancellation_token.dart';
import 'trace_sink_web.dart';

/// Browser traces are a bounded, disposable recording. Server traces remain
/// durable on the server and can be paged through the authenticated protocol.
class TraceStore {
  TraceStore._(this.path) { sink = TraceSink(_record); }
  final String path;
  late final TraceSink sink;
  final _events = <Map<String, dynamic>>[];
  final _bindings = <String, String>{};
  int _sequence = 0;
  bool _closed = false;

  static Future<TraceStore> open(String path, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    return TraceStore._(path);
  }

  void _record(Object? raw) {
    if (_closed || raw is! Map) return;
    if (raw['bind'] case final String trace) _bindings[trace] = raw['session'] as String;
    if (raw['event'] case final Map<Object?, Object?> event) {
      _events.add({'sequence': ++_sequence, 'trace': raw['trace'], 'session': raw['session'],
        'event': Map<String, dynamic>.from(event)});
      if (_events.length > 10000) _events.removeRange(0, 1000);
    }
  }

  Future<Map<String, dynamic>> page(String session, {int after = 0, int? through,
    int limit = 500, required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    final rows = _events.where((row) => row['session'] == session || _bindings[row['trace']] == session)
      .where((row) => (row['sequence'] as int) > after && (row['sequence'] as int) <= (through ?? _sequence))
      .take(limit).toList();
    return {'events': rows.map((row) => row['event']).toList(),
      'after': rows.isEmpty ? after : rows.last['sequence'], 'through': through ?? _sequence, 'done': rows.length < limit};
  }

  Future<Map<String, dynamic>> status(String session, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    return {'through': _sequence};
  }

  Future<void> close() async { _closed = true; _events.clear(); _bindings.clear(); }
}
