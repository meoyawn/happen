import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('removed projects stay removed through discovery and relaunch until explicitly reopened', () async {
    final temporary = await Directory.systemTemp.createTemp('desktop-project-catalog-');
    final root = Directory(await temporary.resolveSymbolicLinks());
    final work = await Directory('${root.path}/work').create();
    final server = await AgentServer.startLocal(directory: '${root.path}/server', skillsHome: root.path);
    DesktopSession? desktop;
    final creator = AgentClient.local(server);
    addTearDown(() async {
      await desktop?.close();
      await creator.close();
      await server.close();
      await root.delete(recursive: true);
    });
    final active = jsonObject(await creator.request('thread/start', {'cwd': work.path}))['thread']['id'] as String;
    final archived = jsonObject(await creator.request('thread/start', {'cwd': work.path}))['thread']['id'] as String;
    await creator.request('thread/archive', {'threadId': archived});
    var session = desktop = DesktopSession(AgentClient.local(server), await openDesktopDatabase(root.path));
    await session.load();
    expect(session.projects.single.tasks.map((task) => task.id), unorderedEquals([active, archived]));
    await session.removeProject(session.projects.single);
    await session.refreshProjects();
    expect(session.projects, isEmpty);
    await session.addProject(work.path, discovered: true);
    expect(session.projects, isEmpty, reason: 'Configured workspaces also respect removal');

    await session.close();
    desktop = null;
    session = desktop = DesktopSession(AgentClient.local(server), await openDesktopDatabase(root.path));
    await session.load();
    expect(session.projects, isEmpty);
    final history = jsonObject(await creator.request('thread/read', {'threadId': active}));
    expect(history['thread']['id'], active);

    await session.addProject(work.path);
    expect(session.projects.single.tasks.map((task) => task.id), unorderedEquals([active, archived]));
    await session.close();
    desktop = null;
    session = desktop = DesktopSession(AgentClient.local(server), await openDesktopDatabase(root.path));
    await session.load();
    expect(session.projects.single.tasks.map((task) => task.id), unorderedEquals([active, archived]));
  });

  test('server scopes share one writer and closing a remote preserves the other catalogs', () async {
    final temporary = await Directory.systemTemp.createTemp('desktop-shared-catalog-');
    final root = Directory(await temporary.resolveSymbolicLinks());
    final work = await Directory('${root.path}/work').create();
    final server = await AgentServer.startLocal(directory: '${root.path}/server', skillsHome: root.path);
    final creator = AgentClient.local(server);
    final database = await openDesktopDatabase(root.path);
    final local = DesktopSession(AgentClient.local(server), database);
    DesktopSession? alpha, beta;
    addTearDown(() async {
      await alpha?.close(); await beta?.close(); await local.close();
      await creator.close(); await server.close(); await root.delete(recursive: true);
    });
    // Copied server catalogs can contain the same native thread ID and cwd.
    final id = jsonObject(await creator.request('thread/start', {'cwd': work.path}))['thread']['id'] as String;
    await local.load();
    alpha = DesktopSession(AgentClient.local(server), database, sidebarOwner: local, machineAlias: 'alpha');
    beta = DesktopSession(AgentClient.local(server), database, sidebarOwner: local, machineAlias: 'beta');
    await Future.wait([alpha.load(), beta.load()]);
    for (final machine in ['', 'alpha', 'beta']) {
      final saved = jsonObject(await callIsolate(database.port, 'load', {'machine': machine}));
      expect((saved['projects'] as List).single['path'], work.path);
      expect((saved['tasks'] as List).single['id'], id);
    }
    await alpha.renameProject(alpha.projects.single, 'Alpha workspace');
    await beta.renameProject(beta.projects.single, 'Beta workspace');
    await alpha.removeProject(alpha.projects.single);
    await Future.wait([alpha.refreshProjects(), beta.refreshProjects(), local.refreshProjects()]);
    expect(alpha.projects, isEmpty);
    expect(beta.projects.single.tasks.single.id, id);
    expect(local.projects.single.tasks.single.id, id);
    await alpha.close(); alpha = null;
    await beta.refreshProjects();
    expect(beta.projects.single.name, 'Beta workspace');
    await local.refreshProjects();
    expect(local.projects.single.tasks.single.id, id);
    alpha = DesktopSession(AgentClient.local(server), database, sidebarOwner: local, machineAlias: 'alpha');
    await alpha.load();
    expect(alpha.projects, isEmpty);
    final betaSaved = jsonObject(await callIsolate(database.port, 'load', {'machine': 'beta'}));
    expect(betaSaved['settings']['project_name:${beta.projects.single.checkoutKey}'], 'Beta workspace');
  });

  test('upgrades and imports connection files into the shared WAL catalog without losing scoped data', () async {
    final root = await Directory.systemTemp.createTemp('desktop-catalog-import-');
    IsolateOwner? database;
    addTearDown(() async { await database?.close(); await root.delete(recursive: true); });
    void seed(String path, String title) {
      final db = sqlite3.open(path);
      try {
        db.execute('''
          PRAGMA journal_mode=WAL;
          CREATE TABLE projects(checkout_key TEXT PRIMARY KEY,identity TEXT NOT NULL,path TEXT NOT NULL UNIQUE);
          CREATE TABLE tasks(id TEXT PRIMARY KEY,checkout_key TEXT NOT NULL REFERENCES projects(checkout_key),title TEXT NOT NULL,archived INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
          PRAGMA user_version=3;
        ''');
        db.execute('INSERT INTO projects VALUES (?,?,?)', ['checkout', 'path:/work', '/work']);
        db.execute('INSERT INTO tasks VALUES (?,?,?,?)', ['thread', 'checkout', title, 1]);
        db.execute('INSERT INTO settings VALUES (?,?)', ['project_name:checkout', title]);
      } finally { db.close(); }
    }
    seed('${root.path}/desktop.sqlite', 'Local');
    final sources = <File>[];
    for (final machine in ['alpha', 'beta']) {
      final key = sha256.convert(utf8.encode(machine)).toString().substring(0, 24);
      final directory = await Directory('${root.path}/remotes/$key').create(recursive: true);
      final source = File('${directory.path}/desktop.sqlite');
      seed(source.path, machine);
      sources.add(source);
    }
    final writer = database = await openDesktopDatabase(root.path);
    await expectLater(openDesktopDatabase(root.path), throwsStateError);
    for (final machine in ['alpha', 'beta', 'alpha']) {
      await callIsolate(writer.port, 'machine.import', {'machine': machine});
    }
    final snapshots = await Future.wait([for (final machine in ['', 'alpha', 'beta'])
      callIsolate(writer.port, 'load', {'machine': machine})]);
    for (final (index, name) in ['Local', 'alpha', 'beta'].indexed) {
      final saved = jsonObject(snapshots[index]);
      expect((saved['projects'] as List).single['checkout_key'], 'checkout');
      expect((saved['tasks'] as List).single, containsPair('title', name));
      expect((saved['tasks'] as List).single['last_activity'], 1);
      expect(saved['settings']['project_name:checkout'], name);
    }
    for (final source in sources) { expect(await source.exists(), isFalse); }
    final reader = sqlite3.open('${root.path}/desktop.sqlite', mode: OpenMode.readOnly);
    try {
      reader.execute('BEGIN');
      expect(reader.select('PRAGMA journal_mode').single.values.single, 'wal');
      expect(reader.select('SELECT count(*) AS count FROM projects').single['count'], 3);
      await callIsolate(writer.port, 'project.remove', {'machine': 'alpha', 'checkout_key': 'checkout'});
      expect(reader.select('SELECT count(*) AS count FROM projects').single['count'], 3,
        reason: 'A WAL snapshot remains stable while the writer commits');
      final current = jsonObject(await callIsolate(writer.port, 'load', {'machine': 'alpha'}));
      expect(current['projects'], isEmpty);
      expect(current['tasks'], isEmpty);
    } finally { reader.close(); }
    await writer.close(); database = null;
    final reopened = database = await openDesktopDatabase(root.path);
    final removed = jsonObject(await callIsolate(reopened.port, 'load', {'machine': 'alpha'}));
    expect(removed['projects'], isEmpty);
    final beta = jsonObject(await callIsolate(reopened.port, 'load', {'machine': 'beta'}));
    expect((beta['tasks'] as List).single['title'], 'beta');
  });
}
