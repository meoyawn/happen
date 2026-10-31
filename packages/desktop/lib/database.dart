import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';

/// One isolate owns the desktop's only SQLite connection, including all reads.
Future<IsolateOwner> openDesktopDatabase(String directory) =>
    IsolateOwner.start(_databaseMain, {'directory': directory});

void _databaseMain(List<Object?> args) async {
  final directory = jsonObject(args[1])['directory'] as String;
  Directory(directory).createSync(recursive: true);
  final db = sqlite3.open('$directory/desktop.sqlite');
  final port = ReceivePort();
  try {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=NORMAL');
    db.execute('PRAGMA foreign_keys=ON');
    final version =
        db.select('PRAGMA user_version').single.values.single as int;
    if (version > 4) {
      throw StateError('Desktop database is from a newer version');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS projects (
        checkout_key TEXT PRIMARY KEY,
        identity TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE
      );
      CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY,
        checkout_key TEXT NOT NULL REFERENCES projects(checkout_key),
        title TEXT NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0,
        last_activity INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    if (!db.select('PRAGMA table_info(tasks)').any((row) => row['name'] == 'archived')) {
      db.execute('ALTER TABLE tasks ADD COLUMN archived INTEGER NOT NULL DEFAULT 0');
    }
    if (!db.select('PRAGMA table_info(tasks)').any((row) => row['name'] == 'last_activity')) {
      db.execute('ALTER TABLE tasks ADD COLUMN last_activity INTEGER NOT NULL DEFAULT 0');
    }
    if (version < 4) {
      // Older references retain their global creation order until activity is
      // observed. Finish this backfill even if an earlier launch stopped after
      // adding the column, without loading every server transcript for Recents.
      db.execute('UPDATE tasks SET last_activity = rowid WHERE last_activity = 0');
    }
    db.execute('PRAGMA user_version=4');
    (args[0] as SendPort).send(port.sendPort);
    await for (final raw in port) {
      final request = jsonObject(raw);
      final reply = request['reply'] as SendPort?;
      final params = jsonObject(request['params']);
      try {
        Object? result;
        switch (request['method']) {
          case 'load':
            result = {
              'settings': {
                for (final row in db.select('SELECT key, value FROM settings'))
                  row['key'] as String: row['value'],
              },
              'projects': db
                  .select(
                    'SELECT checkout_key, identity, path FROM projects ORDER BY rowid',
                  )
                  .map((row) => Map<String, Object?>.from(row))
                  .toList(),
              'tasks': db
                  .select(
                    'SELECT id, checkout_key, title, archived, last_activity FROM tasks ORDER BY rowid DESC',
                  )
                  .map((row) => Map<String, Object?>.from(row))
                  .toList(),
            };
          case 'project.add':
            db.execute(
              'INSERT INTO projects(checkout_key, identity, path) VALUES (?, ?, ?)',
              [params['checkout_key'], params['identity'], params['path']],
            );
          case 'project.remove':
            db.execute('BEGIN IMMEDIATE');
            try {
              db.execute('DELETE FROM tasks WHERE checkout_key IS ?', [params['checkout_key']]);
              db.execute('DELETE FROM projects WHERE checkout_key IS ?', [params['checkout_key']]);
              db.execute('COMMIT');
            } catch (_) {
              db.execute('ROLLBACK');
              rethrow;
            }
          case 'settings.set':
            db.execute(
              'INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
              [params['key'], params['value']],
            );
          case 'project.identify':
            db.execute(
              'UPDATE projects SET identity = ? WHERE checkout_key IS ?',
              [params['identity'], params['checkout_key']],
            );
          case 'task.add':
            db.execute(
              'INSERT INTO tasks(id, checkout_key, title, last_activity) VALUES (?, ?, ?, ?)',
              [params['id'], params['checkout_key'], params['title'], params['last_activity'] ?? DateTime.now().millisecondsSinceEpoch],
            );
          case 'task.activity':
            db.execute('UPDATE tasks SET last_activity = MAX(last_activity, ?) WHERE id IS ?', [params['last_activity'], params['task_id']]);
          case 'task.archive':
            db.execute('UPDATE tasks SET archived = ? WHERE id IS ?', [params['archived'] == true ? 1 : 0, params['task_id']]);
          case 'close':
            reply?.send({'result': null});
            return;
          case 'cancel':
            // Each small SQL operation finishes atomically before the next
            // mailbox message. There is no asynchronous work to leave running.
            continue;
          default:
            throw ArgumentError('Unknown desktop database operation');
        }
        reply?.send({'result': result});
      } catch (error) {
        reply?.send({'error': error.toString()});
      }
    }
  } finally {
    db.close();
    port.close();
  }
}
