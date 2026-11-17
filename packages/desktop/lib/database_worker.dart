@JS()
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart' as web;
import 'database_queries.dart';

@JS('self')
external web.SharedWorkerGlobalScope get _worker;

void main() {
  Future<({CommonDatabase database, IndexedDbFileSystem files})>? opening;
  var queue = Future<void>.value();
  Future<({CommonDatabase database, IndexedDbFileSystem files})> open() async {
    final sqlite = await WasmSqlite3.loadFromUrlString('sqlite3.wasm');
    final files = await IndexedDbFileSystem.open(dbName: 'happen-sqlite', writeAutomatically: false);
    sqlite.registerVirtualFileSystem(files, makeDefault: true);
    final db = sqlite.open('/client.sqlite');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA journal_mode=DELETE');
    db.execute('PRAGMA synchronous=FULL');
    final version = db.select('PRAGMA user_version').single.values.single as int;
    if (version > 7) throw StateError('Client database is from a newer version');
    db.execute(desktopSchema);
    db.execute('CREATE TABLE IF NOT EXISTS browser_files (id TEXT PRIMARY KEY, name TEXT NOT NULL, data TEXT NOT NULL)');
    db.execute('PRAGMA user_version=7');
    await files.flush();
    return (database: db, files: files);
  }

  _worker.onconnect = ((web.MessageEvent event) {
    final port = event.ports.toDart.single;
    final cancelled = <int>{};
    port.onmessage = ((web.MessageEvent event) {
      final request = jsonObject(jsonDecode((event.data as JSString).toDart));
      final id = request['id'] as int;
      if (request['method'] == 'cancel') { cancelled.add(id); return; }
      queue = queue.then((_) async {
        try {
          if (cancelled.remove(id)) return;
          final owner = await (opening ??= open());
          if (cancelled.remove(id)) return;
          final method = requiredString(request, 'method'), params = jsonObject(request['params']);
          final db = owner.database;
          Object? result;
          switch (method) {
            case 'open': break;
            case 'files.put':
              db.execute('INSERT INTO browser_files(id,name,data) VALUES(?,?,?)', [params['id'], params['name'], params['data']]);
            case 'files.read':
              final rows = db.select('SELECT name,data FROM browser_files WHERE id IS ?', [params['id']]);
              result = rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
            case 'files.remove': db.execute('DELETE FROM browser_files WHERE id IS ?', [params['id']]);
            case 'load' || 'remotes.list': result = readDesktopDatabase((execute: db.execute, select: db.select), method, params);
            default: result = writeDesktopDatabase((execute: db.execute, select: db.select), method, params);
          }
          // This VFS buffers IndexedDB writes. Acknowledge persistence only
          // after its explicit flush commits the browser transaction.
          await owner.files.flush();
          if (!cancelled.remove(id)) port.postMessage(jsonEncode({'id': id, 'result': result}).toJS);
        } catch (error) {
          if (!cancelled.remove(id)) port.postMessage(jsonEncode({'id': id, 'error': '$error'}).toJS);
        }
      });
    }).toJS;
    port.start();
  }).toJS;
}
