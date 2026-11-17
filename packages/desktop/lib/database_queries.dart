import 'dart:convert';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/common.dart';
import 'remote_connection.dart';

typedef DesktopSql = ({void Function(String, [List<Object?>]) execute,
  ResultSet Function(String, [List<Object?>]) select});

const desktopSchema = '''
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

Object? readDesktopDatabase(DesktopSql db, String method, Json params) {
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

Object? writeDesktopDatabase(DesktopSql db, String method, Json params) {
  final machine = params['machine'] as String? ?? '';
  switch (method) {
    case 'machine.import':
      break;
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
