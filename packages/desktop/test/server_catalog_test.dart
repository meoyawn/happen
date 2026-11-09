import 'dart:convert';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('desktop rebuilds its thread cache from the server SQLite catalog, including missing folders', () async {
    final made = await Directory.systemTemp.createTemp('desktop-server-catalog-');
    final root = Directory(await made.resolveSymbolicLinks());
    final data = await Directory('${root.path}/server').create();
    final checkout = await Directory('${root.path}/checkout').create();
    final removed = await Directory('${root.path}/removed-checkout').create();
    final cancellation = TimeoutCancellationToken(const Duration(minutes: 1));
    AgentServer? server;
    AgentClient? creator;
    DesktopSession? desktop;
    addTearDown(() async {
      await desktop?.close(); await creator?.close(); await server?.close();
      cancellation.cancel(); await root.delete(recursive: true);
    });
    await File('${data.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt',
      'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    Future<AgentServer> start() => AgentServer.startLocal(directory: data.path, skillsHome: root.path,
      configPath: '${root.path}/config.yaml', telemetry: false);
    server = await start(); creator = AgentClient.local(server);
    Future<String> thread(String cwd, String name) async {
      final page = jsonObject(await creator!.request('thread/start', {'cwd': cwd}));
      final id = page['thread']['id'] as String;
      await creator!.request('thread/name/set', {'threadId': id, 'name': name});
      return id;
    }
    final first = await thread(checkout.path, 'Authoritative title');
    final archived = await thread(checkout.path, 'Archived on the server');
    final missing = await thread(removed.path, 'History with a missing checkout');
    await creator.request('thread/archive', {'threadId': archived});
    await creator.close(); creator = null;
    await server.close(); server = await start();
    await removed.delete();

    final database = await openDesktopDatabase('${root.path}/desktop');
    desktop = DesktopSession(AgentClient.local(server), database);
    await callIsolate(database.port, 'project.add', {'checkout_key': 'cached', 'identity': 'old', 'path': checkout.path});
    for (final id in [first, 'deleted-on-the-server']) {
      await callIsolate(database.port, 'task.add', {'id': id, 'checkout_key': 'cached',
        'title': 'Stale desktop title', 'archived': true, 'last_activity': 9999999999999});
    }
    await desktop.load();
    final projects = desktop.projects;
    final tasks = projects.expand((project) => project.tasks).toList();
    expect(tasks.map((task) => task.id).toSet(), {first, archived, missing});
    expect(tasks.singleWhere((task) => task.id == first).title, 'Authoritative title');
    expect(tasks.singleWhere((task) => task.id == first).archived, isFalse);
    expect(tasks.singleWhere((task) => task.id == first).lastActivity, lessThan(9999999999999));
    expect(tasks.singleWhere((task) => task.id == archived).archived, isTrue);
    final unavailable = projects.singleWhere((project) => project.path == removed.path);
    expect(unavailable.available, isFalse);
    expect(unavailable.tasks.single.id, missing);
    final cached = jsonObject(await callIsolate(database.port, 'load', {}));
    expect((cached['tasks'] as List).map((value) => value['id']).toSet(), {first, archived, missing});
    await desktop.select(unavailable, unavailable.tasks.single);
    expect(unavailable.tasks.single.loaded, isTrue, reason: 'Stored history does not require its checkout to exist');
  });
}
