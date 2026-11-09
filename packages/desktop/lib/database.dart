import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:telemetry/telemetry.dart';

import 'remote_connection.dart';

final _writers = <String, Object>{};

/// One desktop-wide writer; independent read isolates open WAL snapshots.
Future<IsolateOwner> openDesktopDatabase(String directory, {CancellationToken? cancellation}) async {
  final token = cancellation ?? CancellationToken();
  final canonical = await CancellableIsolate.run(() async =>
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

const _schema = '''
  CREATE TABLE IF NOT EXISTS projects (
    machine TEXT NOT NULL, checkout_key TEXT NOT NULL, identity TEXT NOT NULL, path TEXT NOT NULL,
    PRIMARY KEY(machine,checkout_key), UNIQUE(machine,path)
  );
  CREATE TABLE IF NOT EXISTS tasks (
    machine TEXT NOT NULL, id TEXT NOT NULL, checkout_key TEXT NOT NULL, title TEXT NOT NULL,
    archived INTEGER NOT NULL DEFAULT 0, last_activity INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(machine,id), FOREIGN KEY(machine,checkout_key) REFERENCES projects(machine,checkout_key)
  );
  CREATE TABLE IF NOT EXISTS settings (
    machine TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(machine,key)
  );
  CREATE TABLE IF NOT EXISTS removed_projects (
    machine TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(machine,path)
  );
  CREATE TABLE IF NOT EXISTS remote_servers (
    alias TEXT PRIMARY KEY, name TEXT NOT NULL, host TEXT NOT NULL,
    username TEXT, port INTEGER, identity_file TEXT, projects TEXT NOT NULL
  );
''';

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
    db.execute(_schema);
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
      final id = requiredString(request, 'operation_id'), token = operations[id] = CancellationToken();
      final before = writes, read = method == 'load' || method == 'remotes.list';
      final operation = () async {
        // A read observes earlier committed writes, without holding up later writes.
        await before;
        await traceIncoming(request, () async {
          try {
            token.throwIfCancelled();
            final params = jsonObject(request['params']);
            final result = read ? await _readSnapshot(directory, method, params, token)
              : _writeRequest(db, directory, method, params);
            reply?.send({'result': result});
          } catch (error) {
            reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
          } finally { operations.remove(id); token.cancel(); }
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
  return CancellableIsolate.run(() => withTrace(traceContextFrom(carrier, service: 'desktop.storage'), () async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
    try {
      while (true) {
        TracedDatabase? db;
        try {
          db = openTracedDatabase('$directory/desktop.sqlite', mode: OpenMode.readOnly);
          db.execute('PRAGMA query_only=ON'); db.execute('BEGIN');
          return _readRequest(db, method, params);
        } on SqliteException catch (error) {
          if (error.resultCode != 5) rethrow;
          db?.close(); db = null;
          await cancellableDelay(const Duration(milliseconds: 20), deadline);
        } finally { db?.close(); }
      }
    } finally { deadline.cancel(); }
  }), cancellation);
}

Object? _readRequest(TracedDatabase db, String method, Json params) {
  if (method == 'remotes.list') {
    return [for (final row in db.select('SELECT * FROM remote_servers ORDER BY rowid')) {
      'alias': row['alias'], 'name': row['name'], 'host': row['host'], 'user': row['username'],
      'port': row['port'], 'identityFile': row['identity_file'], 'projects': jsonDecode(row['projects'] as String),
    }];
  }
  final machine = params['machine'] as String? ?? '';
  return {
    'settings': {for (final row in db.select('SELECT key,value FROM settings WHERE machine IS ?', [machine]))
      row['key'] as String: row['value']},
    'projects': [for (final row in db.select('SELECT checkout_key,identity,path FROM projects WHERE machine IS ? ORDER BY rowid', [machine]))
      Map<String, Object?>.from(row)],
    'tasks': [for (final row in db.select('SELECT id,checkout_key,title,archived,last_activity FROM tasks WHERE machine IS ? ORDER BY rowid DESC', [machine]))
      Map<String, Object?>.from(row)],
  };
}

Object? _writeRequest(TracedDatabase db, String directory, String method, Json params) {
  final machine = params['machine'] as String? ?? '';
  switch (method) {
    case 'machine.import':
      _importMachine(db, directory, machine);
    case 'remotes.save':
      final remote = remoteMachine(params);
      db.execute('''INSERT INTO remote_servers(alias,name,host,username,port,identity_file,projects)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(alias) DO UPDATE SET name=excluded.name,host=excluded.host,
        username=excluded.username,port=excluded.port,identity_file=excluded.identity_file,projects=excluded.projects''',
        [remote.alias, remote.name, remote.host, remote.user, remote.port, remote.identityFile, jsonEncode(remote.projects)]);
    case 'remotes.remove':
      db.execute('DELETE FROM remote_servers WHERE alias IS ?', [params['alias']]);
    case 'project.add':
      db.execute('BEGIN IMMEDIATE');
      try {
        final path = params['path'];
        if (params['discovered'] == true &&
            db.select('SELECT 1 FROM removed_projects WHERE machine IS ? AND path IS ?', [machine, path]).isNotEmpty) {
          db.execute('COMMIT');
          return null;
        }
        db.execute('INSERT INTO projects(machine,checkout_key,identity,path) VALUES (?,?,?,?) ON CONFLICT(machine,path) DO NOTHING',
          [machine, params['checkout_key'], params['identity'], path]);
        if (params['discovered'] != true) {
          db.execute('DELETE FROM removed_projects WHERE machine IS ? AND path IS ?', [machine, path]);
        }
        final row = db.select('SELECT checkout_key,identity,path FROM projects WHERE machine IS ? AND path IS ?', [machine, path]).single;
        db.execute('COMMIT');
        return Map<String, Object?>.from(row);
      } catch (_) { db.execute('ROLLBACK'); rethrow; }
    case 'project.remove':
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute('''INSERT INTO removed_projects(machine,path) SELECT machine,path FROM projects
          WHERE machine IS ? AND checkout_key IS ? ON CONFLICT DO NOTHING''', [machine, params['checkout_key']]);
        db.execute('DELETE FROM tasks WHERE machine IS ? AND checkout_key IS ?', [machine, params['checkout_key']]);
        db.execute('DELETE FROM projects WHERE machine IS ? AND checkout_key IS ?', [machine, params['checkout_key']]);
        db.execute('COMMIT');
      } catch (_) { db.execute('ROLLBACK'); rethrow; }
    case 'settings.set':
      db.execute('INSERT INTO settings(machine,key,value) VALUES (?,?,?) ON CONFLICT(machine,key) DO UPDATE SET value=excluded.value',
        [machine, params['key'], params['value']]);
    case 'project.identify':
      db.execute('UPDATE projects SET identity=? WHERE machine IS ? AND checkout_key IS ?',
        [params['identity'], machine, params['checkout_key']]);
    case 'task.add':
      // A stale refresh must not restore references after their project was removed.
      db.execute('''INSERT INTO tasks(machine,id,checkout_key,title,archived,last_activity)
        SELECT ?,?,?,?,?,? WHERE EXISTS (SELECT 1 FROM projects WHERE machine IS ? AND checkout_key IS ?)
        ON CONFLICT(machine,id) DO UPDATE SET checkout_key=excluded.checkout_key,title=excluded.title,
        archived=excluded.archived,last_activity=MAX(tasks.last_activity,excluded.last_activity)''',
        [machine, params['id'], params['checkout_key'], params['title'], params['archived'] == true ? 1 : 0,
          params['last_activity'] ?? DateTime.now().millisecondsSinceEpoch, machine, params['checkout_key']]);
    case 'task.activity':
      db.execute('UPDATE tasks SET last_activity=MAX(last_activity,?) WHERE machine IS ? AND id IS ?',
        [params['last_activity'], machine, params['task_id']]);
    case 'tasks.remove':
      for (final id in params['ids'] as List) { db.execute('DELETE FROM tasks WHERE machine IS ? AND id IS ?', [machine, id]); }
    case 'task.archive':
      db.execute('UPDATE tasks SET archived=? WHERE machine IS ? AND id IS ?', [params['archived'] == true ? 1 : 0, machine, params['task_id']]);
    default: throw ArgumentError('Unknown desktop database operation');
  }
  return null;
}
