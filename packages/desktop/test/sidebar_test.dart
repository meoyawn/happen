import 'dart:async';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  for (final interrupted in [false, true]) {
    test('sidebar upgrades ${interrupted ? 'interrupted' : 'old'} references and retains pins, disclosure, and activity across relaunch', () async {
      final root = await Directory.systemTemp.createTemp('desktop-sidebar-');
      final alpha = await Directory('${root.path}/alpha').create();
      final beta = await Directory('${root.path}/beta').create();
      DesktopSession? desktop;
      addTearDown(() async {
        await desktop?.close();
        await root.delete(recursive: true);
      });
      final legacy = sqlite3.open('${root.path}/desktop.sqlite');
      legacy.execute('''
        CREATE TABLE projects (checkout_key TEXT PRIMARY KEY, identity TEXT NOT NULL, path TEXT NOT NULL UNIQUE);
        CREATE TABLE tasks (id TEXT PRIMARY KEY, checkout_key TEXT NOT NULL REFERENCES projects(checkout_key), title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        PRAGMA user_version=3;
      ''');
      for (final (id, path) in [('alpha', alpha.path), ('beta', beta.path)]) {
        legacy.execute('INSERT INTO projects VALUES (?, ?, ?)', [id, path, path]);
      }
      for (final (id, project, archived) in [
        ('old', 'alpha', 0), ('middle', 'beta', 0), ('new', 'alpha', 0), ('archived', 'beta', 1),
      ]) {
        legacy.execute('INSERT INTO tasks VALUES (?, ?, ?, ?)', [id, project, id, archived]);
      }
      if (interrupted) legacy.execute('ALTER TABLE tasks ADD COLUMN last_activity INTEGER NOT NULL DEFAULT 0');
      legacy.close();

      var client = _Client();
      var database = await openDesktopDatabase(root.path);
      var session = desktop = DesktopSession(client, database);
      await session.load();
      expect(session.recentTasks.map((entry) => entry.$2.id), ['new', 'middle', 'old']);
      final firstProject = session.projects.first, secondProject = session.projects.last;
      final newest = firstProject.tasks.singleWhere((task) => task.id == 'new');
      await session.pinTask(newest, true);
      await session.pinProject(secondProject, true);
      await session.chooseSidebarSection('pinned', true);
      await session.chooseSidebarSection('recents', true);
      expect(session.recentTasks.map((entry) => entry.$2.id), ['middle', 'old']);

      client.events.add({
        'task_id': 'old', 'seq': 1, 'type': 'turn.completed',
        'created_at': '2030-01-02T00:00:00Z', 'data': {},
      });
      // Later arrivals and token deltas must not rewind or reshuffle activity.
      client.events.add({
        'task_id': 'old', 'seq': 2, 'type': 'turn.completed',
        'created_at': '2030-01-01T00:00:00Z', 'data': {},
      });
      client.events.add({
        'task_id': 'middle', 'type': 'text.delta', 'delta': 'Partial reply',
        'created_at': '2031-01-01T00:00:00Z',
      });
      await Future<void>.delayed(Duration.zero);
      await callIsolate(database.port, 'load', {});
      expect(session.recentTasks.map((entry) => entry.$2.id), ['old', 'middle']);
      expect(session.error, isNull);
      await session.close();
      desktop = null;

      client = _Client();
      database = await openDesktopDatabase(root.path);
      session = desktop = DesktopSession(client, database);
      await session.load();
      expect(session.pinnedTaskIds, ['new']);
      expect(session.pinnedProjectKeys, ['beta']);
      expect(session.collapsedSidebarSections, {'pinned', 'recents'});
      expect(session.recentTasks.map((entry) => entry.$2.id), ['old', 'middle']);
      expect(session.recentTasks.first.$2.lastActivity, DateTime.utc(2030, 1, 2).millisecondsSinceEpoch);
      await session.pinTask(session.projects.first.tasks.singleWhere((task) => task.id == 'new'), false);
      expect(session.recentTasks.map((entry) => entry.$2.id), ['old', 'new', 'middle']);
      await session.pinProject(session.projects.last, false);
      await session.chooseSidebarSection('pinned', false);
      await session.chooseSidebarSection('recents', false);
      expect(session.pinnedTaskIds, isEmpty);
      expect(session.pinnedProjectKeys, isEmpty);
      expect(session.collapsedSidebarSections, isEmpty);
    });
  }
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => true;
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'providers.list') return {'providers': []};
    throw StateError('Unexpected request: $method');
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
