import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:telemetry/telemetry.dart';

import 'database_queries.dart';

final _writers = <String, Object>{};

typedef DesktopDatabase = IsolateOwner;

Future<Object?> desktopDatabaseRequest(DesktopDatabase database, String method, Json params,
    {CancellationToken? cancellation}) async {
  cancellation?.throwIfCancelled();
  return callIsolate(database.port, method, params,
    cancellation: _readsSnapshot(method) ? cancellation : null);
}

bool _readsSnapshot(String method) => method == 'load' || method == 'remotes.list';

/// One desktop-wide writer; independent read isolates open WAL snapshots.
Future<IsolateOwner> openDesktopDatabase(String directory, {CancellationToken? cancellation}) async {
  final token = cancellation ?? CancellationToken();
  final canonical = await computeCancellable(() async =>
    (await Directory(directory).create(recursive: true)).resolveSymbolicLinks(), token);
  if (_writers.containsKey(canonical)) throw StateError('Desktop database already has a writer');
  final reservation = _writers[canonical] = Object();
  void release() => _writers.removeWhere((key, value) => key == canonical && identical(value, reservation));
  try {
    final owner = await IsolateOwner.start(_databaseMain, {'directory': canonical}, service: 'desktop.storage');
    unawaited(owner.done.whenComplete(release));
    return owner;
  } catch (_) { release(); rethrow; }
}


bool _hasTable(TracedDatabase db, String table) =>
  db.select("SELECT 1 FROM sqlite_master WHERE type IS 'table' AND name IS ?", [table]).isNotEmpty;

Set<String> _columns(TracedDatabase db, String table) =>
  {for (final row in db.select('PRAGMA table_info($table)')) row['name'] as String};

void _initialize(TracedDatabase db, String directory) {
  db.execute('PRAGMA journal_mode=WAL');
  db.execute('PRAGMA synchronous=FULL');
  db.execute('PRAGMA busy_timeout=0');
  final version = db.select('PRAGMA user_version').single.values.single as int;
  if (version > 7) throw StateError('Desktop database is from a newer version');
  db.execute('PRAGMA foreign_keys=OFF');
  db.execute('BEGIN IMMEDIATE');
  try {
    final previous = <String>[];
    if (version < 7) {
      for (final table in ['projects', 'tasks', 'settings']) {
        if (!_hasTable(db, table)) continue;
        db.execute('ALTER TABLE $table RENAME TO previous_$table');
        previous.add(table);
      }
    }
    db.execute(desktopSchema);
    if (previous.contains('projects')) {
      db.execute("INSERT INTO projects SELECT '',checkout_key,identity,path FROM previous_projects ORDER BY rowid");
    }
    if (previous.contains('tasks')) {
      final columns = _columns(db, 'previous_tasks');
      final archived = columns.contains('archived') ? 'archived' : '0';
      final activity = !columns.contains('last_activity') ? 'rowid'
        : version < 4 ? 'CASE WHEN last_activity IS 0 THEN rowid ELSE last_activity END' : 'last_activity';
      db.execute("INSERT INTO tasks SELECT '',id,checkout_key,title,$archived,$activity FROM previous_tasks ORDER BY rowid");
    }
    if (previous.contains('settings')) {
      db.execute("INSERT INTO settings SELECT '',key,value FROM previous_settings");
    }
    for (final table in previous.reversed) { db.execute('DROP TABLE previous_$table'); }
    db.execute("DELETE FROM settings WHERE key IS 'conversation_view'");
    db.execute('PRAGMA user_version=7');
    db.execute('COMMIT');
  } catch (_) { db.execute('ROLLBACK'); rethrow; }
  db.execute('PRAGMA foreign_keys=ON');
  for (final row in db.select('SELECT alias FROM remote_servers')) {
    _importMachine(db, directory, row['alias'] as String);
  }
}

/// Import the former connection-specific files once, before publishing a session.
/// Checkouts and thread IDs are local to their server, including copied catalogs.
void _importMachine(TracedDatabase db, String directory, String machine) {
  if (machine.isEmpty) throw ArgumentError('A remote machine is required');
  final key = sha256.convert(utf8.encode(machine)).toString().substring(0, 24);
  final source = File('$directory/remotes/$key/desktop.sqlite');
  if (!source.existsSync()) return;
  final imported = db.select("SELECT 1 FROM settings WHERE machine IS ? AND key IS 'catalog_imported'", [machine]).isNotEmpty;
  if (!imported) {
    final old = openTracedDatabase(source.path, mode: OpenMode.readOnly);
    try {
      old.execute('PRAGMA query_only=ON'); old.execute('BEGIN');
      final version = old.select('PRAGMA user_version').single.values.single as int;
      if (version > 7) throw StateError('Remote desktop database is from a newer version');
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final row in old.select('SELECT * FROM projects ORDER BY rowid')) {
          db.execute('INSERT INTO projects(machine,checkout_key,identity,path) VALUES (?,?,?,?)',
            [machine, row['checkout_key'], row['identity'], row['path']]);
        }
        final columns = _columns(old, 'tasks');
        for (final row in old.select('SELECT rowid,* FROM tasks ORDER BY rowid')) {
          final activity = columns.contains('last_activity') ? row['last_activity'] as int : 0;
          db.execute('INSERT INTO tasks(machine,id,checkout_key,title,archived,last_activity) VALUES (?,?,?,?,?,?)',
            [machine, row['id'], row['checkout_key'], row['title'], columns.contains('archived') ? row['archived'] : 0,
              version < 4 && activity == 0 ? row['rowid'] : activity]);
        }
        for (final row in old.select('SELECT key,value FROM settings')) {
          db.execute('INSERT INTO settings(machine,key,value) VALUES (?,?,?) ON CONFLICT(machine,key) DO NOTHING',
            [machine, row['key'], row['value']]);
        }
        if (_hasTable(old, 'removed_projects')) {
          for (final row in old.select('SELECT path FROM removed_projects')) {
            db.execute('INSERT INTO removed_projects(machine,path) VALUES (?,?) ON CONFLICT DO NOTHING', [machine, row['path']]);
          }
        }
        db.execute("INSERT INTO settings(machine,key,value) VALUES (?,'catalog_imported','true')", [machine]);
        db.execute('COMMIT');
      } catch (_) { db.execute('ROLLBACK'); rethrow; }
    } finally { old.close(); }
  }
  // A committed import is idempotent even if cleanup was interrupted.
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File('${source.path}$suffix');
    if (file.existsSync()) file.deleteSync();
  }
}

Future<void> _databaseMain(List<Object?> args) async {
  final directory = requiredString(jsonObject(args[1]), 'directory');
  final db = openTracedDatabase('$directory/desktop.sqlite');
  final port = ReceivePort(), stopped = Completer<void>();
  final operations = <String, CancellationToken>{}, readers = <Future<void>>{};
  var writes = Future<void>.value(), closing = false;
  StreamSubscription<Object?>? listener;
  try {
    _initialize(db, directory);
    listener = port.listen((raw) {
      final request = jsonObject(raw), reply = request['reply'] as SendPort?;
      final method = requiredString(request, 'method');
      if (method == 'cancel') { operations[request['params']['operation_id']]?.cancel(); return; }
      if (closing) { reply?.send({'error': 'Desktop database is closing'}); return; }
      if (method == 'close') {
        closing = true;
        for (final token in operations.values) { token.cancel(); }
        unawaited(() async {
          await writes;
          await Future.wait(readers.toList());
          reply?.send({'result': null});
          stopped.complete();
        }());
        return;
      }
      final id = requiredString(request, 'operation_id');
      final before = writes, read = _readsSnapshot(method);
      // Only reads can be cancelled after admission. Close waits for queued commits.
      final token = read ? operations[id] = CancellationToken() : null;
      final operation = () async {
        // A read observes earlier committed writes, without holding up later writes.
        await before;
        await traceIncoming(request, () async {
          try {
            token?.throwIfCancelled();
            final params = jsonObject(request['params']);
            final result = token != null ? await _readSnapshot(directory, method, params, token)
              : _writeNative(db, directory, method, params);
            reply?.send({'result': result});
          } catch (error) {
            reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
          } finally { if (token != null) { operations.remove(id); token.cancel(); } }
        }, service: 'desktop.storage');
      }();
      if (read) {
        readers.add(operation);
        unawaited(operation.whenComplete(() => readers.remove(operation)));
      } else { writes = operation; }
    });
    (args[0] as SendPort).send(port.sendPort);
    await stopped.future;
  } finally { await listener?.cancel(); db.close(); port.close(); }
}

Future<Object?> _readSnapshot(String directory, String method, Json params, CancellationToken cancellation) {
  final carrier = currentTrace?.carrier();
  return computeCancellable(() => withTrace(traceContextFrom(carrier, service: 'desktop.storage'), () async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
    try {
      while (true) {
        TracedDatabase? db;
        try {
          db = openTracedDatabase('$directory/desktop.sqlite', mode: OpenMode.readOnly);
          db.execute('PRAGMA query_only=ON'); db.execute('BEGIN');
          return readDesktopDatabase((execute: db.execute, select: db.select), method, params);
        } on SqliteException catch (error) {
          if (error.resultCode != 5) rethrow;
          db?.close(); db = null;
          await cancellableDelay(const Duration(milliseconds: 20), deadline);
        } finally { db?.close(); }
      }
    } finally { deadline.cancel(); }
  }), cancellation);
}

Object? _writeNative(TracedDatabase db, String directory, String method, Json params) {
  if (method == 'machine.import') {
    _importMachine(db, directory, requiredString(params, 'machine'));
    return null;
  }
  return writeDesktopDatabase((execute: db.execute, select: db.select), method, params);
}
