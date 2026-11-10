import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/machines.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('startup shows the last conversation while model discovery is still pending', () async {
    final directory = await Directory.systemTemp.createTemp('desktop-startup-');
    final database = await openDesktopDatabase(directory.path);
    final client = _StartupClient(directory.path);
    final session = DesktopSession(client, database);
    Future<void>? loading;
    addTearDown(() async {
      if (!client.providers.isCompleted) client.providers.complete({'providers': <Json>[]});
      if (!client.history.isCompleted) client.history.complete(_history());
      await loading;
      await session.close();
      await directory.delete(recursive: true);
    });
    await _saveSelection(database, directory.path);
    loading = session.load();
    await client.historyStarted.future.timeout(const Duration(seconds: 2));
    expect(session.task?.id, 'selected');
    expect(session.openTabIds, ['selected', 'inactive']);

    final shown = Completer<void>();
    void changed() {
      if (session.task?.loaded == true && !shown.isCompleted) shown.complete();
    }
    session.addListener(changed);
    client.history.complete(_history());
    await shown.future.timeout(const Duration(seconds: 2));
    session.removeListener(changed);
    expect(client.providers.isCompleted, isFalse);
    expect(session.task!.messages['answer']?['text'], 'Saved answer');
    expect(client.historyReads, ['selected']);
    expect(session.projects.single.tasks.singleWhere((task) => task.id == 'inactive').loaded, isFalse);
  });

  test('an offline VPS restores its cached threads and last selection after relaunch', () async {
    final directory = await Directory.systemTemp.createTemp('desktop-offline-');
    DesktopSession? session;
    addTearDown(() async {
      await session?.close();
      await directory.delete(recursive: true);
    });
    var database = await openDesktopDatabase(directory.path);
    await _saveSelection(database, '/remote/project', machine: 'vps');
    for (var launch = 0; launch < 2; launch++) {
      if (launch > 0) database = await openDesktopDatabase(directory.path);
      final offline = _StartupClient('/remote/project', offline: true);
      session = DesktopSession(offline, database, machineAlias: 'vps')..connected = false;
      await session.load().timeout(const Duration(seconds: 2));
      await session.refreshSessions();
      expect(session.projects.single.path, '/remote/project');
      expect(session.projects.single.tasks.map((task) => task.id).toSet(), {'selected', 'inactive'});
      expect(session.task?.id, 'selected');
      expect(session.connected, isFalse);
      await session.close();
      session = null;
    }
  });

  test('startup keeps the selected VPS catalog visible through failed SSH attempts', () async {
    final directory = await Directory.systemTemp.createTemp('desktop-machines-startup-');
    final server = await AgentServer.startLocal(directory: '${directory.path}/server',
      configPath: '${directory.path}/config.yaml', skillsHome: directory.path, telemetry: false);
    final database = await openDesktopDatabase(directory.path);
    final local = DesktopSession(AgentClient.local(server), database);
    MachinesController? machines;
    addTearDown(() async {
      await machines?.close();
      await local.close();
      await server.close();
      await directory.delete(recursive: true);
    });
    await _saveSelection(database, '/remote/project', machine: 'vps');
    await callIsolate(database.port, 'remotes.save', {
      'alias': 'vps', 'name': 'VPS', 'host': '127.0.0.1', 'port': 1, 'projects': <String>[],
    });
    await callIsolate(database.port, 'settings.set', {'key': 'active_machine', 'value': 'vps'});
    await local.restore();
    final controller = machines = MachinesController(local, directory.path);
    final cached = Completer<DesktopSession>();
    void changed() {
      final remote = controller.sessions.where((machine) => machine.alias == 'vps').firstOrNull;
      if (remote != null && !cached.isCompleted) cached.complete(remote.session);
    }
    controller.addListener(changed);
    final remote = await cached.future.timeout(const Duration(seconds: 5));
    controller.removeListener(changed);
    await remote.client.events.stream.firstWhere((event) => event['method'] == 'connection/closed')
      .timeout(const Duration(seconds: 5));
    await controller.refreshCatalogs();
    expect(controller.active, same(remote));
    expect(remote.connected, isFalse);
    expect(remote.task?.id, 'selected');
    expect(remote.projects.single.tasks.map((task) => task.id).toSet(), {'selected', 'inactive'});
    expect(controller.sessions.singleWhere((machine) => machine.alias == 'vps').session, same(remote));
  });
}

Future<void> _saveSelection(IsolateOwner database, String path, {String machine = ''}) async {
  Future<Object?> save(String method, Json params) =>
    callIsolate(database.port, method, {'machine': machine, ...params});
  await save('project.add', {'checkout_key': 'project', 'identity': 'repository', 'path': path});
  for (final id in ['selected', 'inactive']) {
    await save('task.add', {'checkout_key': 'project', 'id': id, 'title': id});
  }
  await save('settings.set', {'key': 'open_tabs', 'value': jsonEncode(['selected', 'inactive'])});
  await save('settings.set', {'key': 'active_tab', 'value': 'selected'});
}

Json _history() => {
  'thread': {'id': 'selected', 'name': 'Selected conversation'},
  'configuration': {'provider': 'openai', 'model': 'fixture'},
  'history': {'data': [
    {'turnId': 'turn', 'item': {'id': 'answer', 'type': 'agentMessage', 'text': 'Saved answer'}},
  ], 'turns': <Json>[], 'nextCursor': null},
  'recentTurns': {'data': <Json>[]},
};

class _StartupClient implements AgentClient {
  _StartupClient(this.path, {this.offline = false});
  final String path;
  final bool offline;
  final providers = Completer<Json>(), history = Completer<Json>();
  final historyStarted = Completer<void>();
  final historyReads = <String>[];
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => false;

  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (offline) throw const SocketException('VPS is offline');
    return switch (method) {
      'client.capabilities' => <String, Object?>{},
      'providers.list' => providers.future,
      _ => throw StateError('Unexpected request: $method'),
    };
  }

  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async {
    if (offline) throw const SocketException('VPS is offline');
    if (method == 'thread/read') {
      historyReads.add(params['threadId'] as String);
      if (params['threadId'] != 'selected') throw StateError('Inactive history was requested during startup');
      if (!historyStarted.isCompleted) historyStarted.complete();
      return history.future.asCancellable(cancellation);
    }
    if (method == 'thread/list') return {
      'data': [if (params['archived'] != true)
        for (final id in ['selected', 'inactive'])
          {'id': id, 'cwd': path, 'name': id, 'status': {'type': 'idle'}},
      ], 'nextCursor': null,
    };
    throw StateError('Unexpected read: $method');
  }

  @override Future<Json> inspectWorkspace(String path, {required CancellationToken cancellation}) async =>
    {'path': path, 'available': true, 'identity': 'repository'};
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
