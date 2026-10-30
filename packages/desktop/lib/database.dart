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
    if (version > 2) {
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
        title TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      PRAGMA user_version=2;
    ''');
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
                    'SELECT id, checkout_key, title FROM tasks ORDER BY rowid DESC',
                  )
                  .map((row) => Map<String, Object?>.from(row))
                  .toList(),
            };
          case 'project.add':
            db.execute(
              'INSERT INTO projects(checkout_key, identity, path) VALUES (?, ?, ?)',
              [params['checkout_key'], params['identity'], params['path']],
            );
          case 'settings.set':
            db.execute('INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', [
              params['key'], params['value'],
            ]);
          case 'project.identify':
            db.execute(
              'UPDATE projects SET identity = ? WHERE checkout_key IS ?',
              [params['identity'], params['checkout_key']],
            );
          case 'task.add':
            db.execute(
              'INSERT INTO tasks(id, checkout_key, title) VALUES (?, ?, ?)',
              [params['id'], params['checkout_key'], params['title']],
            );
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
