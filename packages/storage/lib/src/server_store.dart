import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import 'session_reader.dart';

final _catalogs = <String, Object>{};

/// Port of Codex StateRuntime's shared thread catalog. Canonical history keeps
/// its per-thread writer; this one worker owns server-wide metadata and recovery.
Future<IsolateOwner> startServerStore(String directory, {required CancellationToken cancellation}) async {
  final canonical = await CancellableIsolate.run(() async =>
    (await Directory(directory).create(recursive: true)).resolveSymbolicLinks(), cancellation);
  if (_catalogs.containsKey(canonical)) throw StateError('Server catalog already has a writer');
  final reservation = _catalogs[canonical] = Object();
  void release() => _catalogs.removeWhere((key, value) => key == canonical && identical(value, reservation));
  IsolateOwner? owner;
  try {
    owner = await IsolateOwner.start(_serverMain, {'directory': canonical}, service: 'storage.server');
    unawaited(owner.done.whenComplete(release));
    await callIsolate(owner.port, 'recover', {}, cancellation: cancellation, timeout: null);
    return owner;
  } catch (_) {
    try { await owner?.close(); } finally { release(); }
    rethrow;
  }
}

Future<void> _serverMain(List<Object?> args) async {
  final directory = requiredString(jsonObject(args[1]), 'directory');
  final db = openTracedDatabase('$directory/server.sqlite');
  final port = ReceivePort(), queue = StreamController<Json>(), operations = <String, CancellationToken>{};
  StreamSubscription<Object?>? listener;
  var closing = false;
  try {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('PRAGMA busy_timeout=0');
    db.execute('''
      CREATE TABLE IF NOT EXISTS threads (
        id TEXT PRIMARY KEY NOT NULL, cwd TEXT NOT NULL, model_provider TEXT NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, archived INTEGER NOT NULL,
        name TEXT, preview TEXT NOT NULL, search_text TEXT NOT NULL, source_seq INTEGER NOT NULL, data TEXT NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS idx_threads_created ON threads(archived,created_at DESC,id DESC);
      CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(archived,updated_at DESC,id DESC);
      CREATE INDEX IF NOT EXISTS idx_threads_cwd ON threads(archived,cwd,updated_at DESC,id DESC);
      CREATE TABLE IF NOT EXISTS mcp_event_threads(thread_id TEXT PRIMARY KEY NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS dirty_threads(thread_id TEXT PRIMARY KEY NOT NULL,ticket TEXT NOT NULL) STRICT;
    ''');
    listener = port.listen((raw) {
      final request = jsonObject(raw), reply = request['reply'] as SendPort?;
      if (request['method'] == 'cancel') { operations[request['params']['operation_id']]?.cancel(); reply?.send({'result': null}); return; }
      if (closing) { reply?.send({'error': 'Server catalog is closing'}); return; }
      if (request['method'] == 'close') { closing = true; for (final token in operations.values) { token.cancel(); } }
      operations[requiredString(request, 'operation_id')] = CancellationToken(); queue.add(request);
    });
    (args[0] as SendPort).send(port.sendPort);
    await for (final request in queue.stream) {
      final id = requiredString(request, 'operation_id'), cancellation = operations[id]!;
      await traceIncoming(request, () async {
        final reply = request['reply'] as SendPort?;
        try {
          cancellation.throwIfCancelled();
          reply?.send({'result': await _serverRequest(db, directory, requiredString(request, 'method'),
            jsonObject(request['params']), cancellation)});
        } catch (error) {
          traceError(error);
          reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
        } finally { operations.remove(id); cancellation.cancel(); }
      }, service: 'storage.server');
      if (request['method'] == 'close') break;
    }
  } finally { db.close(); await listener?.cancel(); port.close(); unawaited(queue.close()); }
}

void _catalogUpsert(TracedDatabase db, Json row) {
  final id = requiredString(row, 'id'); validateTaskId(id);
  if (row['missing'] == true) {
    db.execute('DELETE FROM threads WHERE id IS ?', [id]);
    db.execute('DELETE FROM mcp_event_threads WHERE thread_id IS ?', [id]); return;
  }
  final thread = jsonObject(row['thread']), sequence = row['sequence'] as int;
  final previous = db.select('SELECT source_seq FROM threads WHERE id IS ?', [id]).firstOrNull;
  if (previous != null && (previous['source_seq'] as int) > sequence) return;
  final cwd = Directory(thread['cwd'] as String).absolute.uri.normalizePath().toString();
  db.execute('''INSERT INTO threads(id,cwd,model_provider,created_at,updated_at,archived,name,preview,search_text,source_seq,data)
    VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
      cwd=excluded.cwd,model_provider=excluded.model_provider,created_at=excluded.created_at,
      updated_at=excluded.updated_at,archived=excluded.archived,name=excluded.name,
      preview=excluded.preview,search_text=excluded.search_text,source_seq=excluded.source_seq,data=excluded.data''',
    [id, cwd, thread['modelProvider'], thread['createdAt'], thread['updatedAt'], row['archived'] == true ? 1 : 0,
      thread['name'], thread['preview'], '${thread['name'] ?? ''} ${thread['preview']}'.toLowerCase(), sequence, jsonEncode(thread)]);
  db.execute(row['recovery'] == true
    ? 'INSERT INTO mcp_event_threads(thread_id) VALUES (?) ON CONFLICT DO NOTHING'
    : 'DELETE FROM mcp_event_threads WHERE thread_id IS ?', [id]);
}

Future<Object?> _serverRequest(TracedDatabase db, String directory, String method, Json params, CancellationToken cancellation) async {
  switch (method) {
    case 'recover':
      final dirty = {for (final row in db.select('SELECT thread_id,ticket FROM dirty_threads')) row['thread_id'] as String: row['ticket']};
      final rows = await readCatalogThreads(directory, dirty.keys.toList(), cancellation: cancellation);
      for (final row in rows) { _catalogSync(db, row, dirty[row['id']] as String); }
      return null;
    case 'thread.dirty':
      final id = requiredString(params, 'threadId'); validateTaskId(id);
      final ticket = newId();
      db.execute('INSERT INTO dirty_threads VALUES (?,?) ON CONFLICT(thread_id) DO UPDATE SET ticket=excluded.ticket', [id, ticket]);
      return ticket;
    case 'thread.sync':
      _catalogSync(db, jsonObject(params['row']), requiredString(params, 'ticket')); return null;
    case 'mcp.threads':
      // Extra candidates remain useful if a process stopped between a thread
      // commit and catalog enrichment. Private archived state is checked again.
      return db.select('''SELECT m.thread_id FROM mcp_event_threads m LEFT JOIN threads t ON t.id IS m.thread_id
        WHERE t.id IS NULL OR t.archived IS 0 ORDER BY m.thread_id''').map((row) => row['thread_id']).toList();
    case 'mcp.track':
    case 'mcp.forget':
      final id = requiredString(params, 'threadId'); validateTaskId(id);
      db.execute(method == 'mcp.track'
        ? 'INSERT INTO mcp_event_threads(thread_id) VALUES (?) ON CONFLICT DO NOTHING'
        : 'DELETE FROM mcp_event_threads WHERE thread_id IS ?', [id]); return null;
    case 'close': return null;
    default: throw StateError('Unknown server catalog operation');
  }
}

void _catalogSync(TracedDatabase db, Json row, String ticket) {
  db.execute('BEGIN');
  try {
    _catalogUpsert(db, row);
    db.execute('DELETE FROM dirty_threads WHERE thread_id IS ? AND ticket IS ?', [row['id'], ticket]);
    db.execute('COMMIT');
  } catch (_) { db.execute('ROLLBACK'); rethrow; }
}
