import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:sqlite3/sqlite3.dart';

/// A dedicated writer keeps trace SQL and its WAL away from history and the UI.
/// Producers send records without waiting; the writer commits bounded batches.
class TraceStore {
  TraceStore._(this.path, this.sink, this._isolate, this._exit, this._errors);
  final String path;
  final SendPort sink;
  final Isolate _isolate;
  final ReceivePort _exit, _errors;
  bool _closed = false;
  String? _failure;

  static Future<TraceStore> open(String path, {required CancellationToken cancellation}) async {
    final ready = ReceivePort(), exit = ReceivePort(), errors = ReceivePort();
    final startup = Completer<SendPort>();
    TraceStore? store;
    final listener = ready.listen((value) {
      if (!startup.isCompleted) startup.complete(value as SendPort);
    });
    errors.listen((error) {
      final failure = 'Trace database worker failed: $error';
      store?._failure = failure;
      if (!startup.isCompleted) startup.completeError(StateError(failure));
    });
    exit.listen((_) {
      store?._failure ??= 'Trace database worker exited';
      if (!startup.isCompleted) startup.completeError(StateError('Trace database worker exited'));
    });
    final isolate = await Isolate.spawn(_traceMain, [ready.sendPort, path],
      onExit: exit.sendPort, onError: errors.sendPort, debugName: 'telemetry');
    try {
      final sink = await startup.future.timeout(const Duration(seconds: 10)).asCancellable(cancellation);
      return store = TraceStore._(path, sink, isolate, exit, errors);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      exit.close();
      errors.close();
      rethrow;
    } finally { await listener.cancel(); ready.close(); }
  }

  Future<Map<String, dynamic>> page(String session, {int after = 0, int? through,
    required CancellationToken cancellation}) => _request({
      'method': 'page', 'session': session, 'after': after, 'through': through,
    }, cancellation);

  Future<Map<String, dynamic>> status(String session, {required CancellationToken cancellation}) =>
    _request({'method': 'status', 'session': session}, cancellation);

  Future<Map<String, dynamic>> _request(Map<String, dynamic> request, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    if (_closed || _failure != null) throw StateError(_failure ?? 'Trace database is closed');
    final reply = ReceivePort();
    sink.send({...request, 'reply': reply.sendPort});
    try {
      final value = Map<String, dynamic>.from(await reply.first
        .timeout(const Duration(seconds: 30)).asCancellable(cancellation) as Map);
      if (value['error'] != null) throw StateError(value['error'] as String);
      return value;
    } finally { reply.close(); }
  }

  Future<void> close() async {
    if (_closed) return;
    try { await _request({'method': 'close'}, CancellationToken()); }
    finally {
      _closed = true;
      _isolate.kill();
      _exit.close();
      _errors.close();
    }
  }
}

void _traceMain(List<Object?> arguments) {
  final path = arguments[1] as String;
  Directory(File(path).parent.path).createSync(recursive: true);
  final db = sqlite3.open(path);
  db.execute('PRAGMA journal_mode=WAL');
  db.execute('PRAGMA synchronous=NORMAL');
  db.execute('PRAGMA busy_timeout=3000');
  db.execute('''
    CREATE TABLE IF NOT EXISTS trace_event (
      seq INTEGER PRIMARY KEY, trace_id TEXT NOT NULL, session_id TEXT,
      ts_us INTEGER NOT NULL, data TEXT NOT NULL
    ) STRICT;
    CREATE INDEX IF NOT EXISTS trace_event_session ON trace_event(session_id, seq);
    CREATE INDEX IF NOT EXISTS trace_event_trace ON trace_event(trace_id, seq);
    CREATE TABLE IF NOT EXISTS session_trace (
      trace_id TEXT NOT NULL, session_id TEXT NOT NULL,
      PRIMARY KEY(trace_id, session_id)
    ) STRICT;
    CREATE INDEX IF NOT EXISTS session_trace_session ON session_trace(session_id, trace_id);
  ''');
  final insert = db.prepare('INSERT INTO trace_event(trace_id, session_id, ts_us, data) VALUES (?, ?, ?, ?)');
  final bind = db.prepare('INSERT OR IGNORE INTO session_trace(trace_id, session_id) VALUES (?, ?)');
  final pending = <Map>[];
  final port = ReceivePort();
  Timer? timer;
  String? failure;

  void flush() {
    timer?.cancel();
    timer = null;
    if (failure != null) throw StateError(failure!);
    if (pending.isEmpty) return;
    db.execute('BEGIN');
    try {
      for (final message in pending) {
        if (message['bind'] != null) {
          bind.execute([message['bind'], message['session']]);
        } else {
          final event = message['event'] as Map;
          insert.execute([message['trace'], message['session'], event['ts'], jsonEncode(event)]);
          if (message['session'] != null) bind.execute([message['trace'], message['session']]);
        }
      }
      db.execute('COMMIT');
      pending.clear();
    } catch (error) {
      db.execute('ROLLBACK');
      failure = error.toString();
      rethrow;
    }
  }

  const filter = '(session_id IS ? OR trace_id IN (SELECT trace_id FROM session_trace WHERE session_id IS ?))';
  (arguments[0] as SendPort).send(port.sendPort);
  port.listen((raw) {
    final message = raw as Map;
    final reply = message['reply'] as SendPort?;
    try {
      if (message.containsKey('event') || message.containsKey('bind')) {
        if (failure != null) return;
        pending.add(message);
        if (pending.length >= 256) { flush(); }
        else { timer ??= Timer(const Duration(milliseconds: 25), () {
          try { flush(); } catch (_) { /* Surface the failure on status/export. */ }
        }); }
        return;
      }
      flush();
      if (message['method'] == 'close') {
        insert.close();
        bind.close();
        db.close();
        port.close();
        reply?.send({'closed': true});
        return;
      }
      final session = message['session'] as String;
      if (message['method'] == 'status') {
        final rows = db.select("SELECT json_extract(data, '\$.cat') AS category, "
          "count(*) AS count FROM trace_event WHERE $filter AND json_extract(data, '\$.ph') IN ('b', 'i') "
          'GROUP BY category', [session, session]);
        reply?.send({'categories': {for (final row in rows) row['category'] as String: row['count']}});
        return;
      }
      final through = message['through'] as int? ??
        db.select('SELECT coalesce(max(seq), 0) AS seq FROM trace_event').single['seq'] as int;
      final after = message['after'] as int;
      final rows = db.select('SELECT seq, data FROM trace_event WHERE seq > ? AND seq <= ? AND $filter ORDER BY seq LIMIT 256',
        [after, through, session, session]);
      reply?.send({
        'through': through, 'after': rows.isEmpty ? through : rows.last['seq'],
        'done': rows.length < 256,
        'events': [for (final row in rows) jsonDecode(row['data'] as String)],
      });
    } catch (error) { reply?.send({'error': error.toString()}); }
  });
}
