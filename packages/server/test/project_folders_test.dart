import 'dart:async';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late AgentServer server;
  late AgentClient client;
  late CancellationToken lifetime;

  Future<String> git(String cwd, List<String> arguments) async {
    final result = await Process.run('git', ['-c', 'core.hooksPath=/dev/null', ...arguments], workingDirectory: cwd);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trim();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('happen-project-folders-');
    addTearDown(() => root.delete(recursive: true));
    lifetime = CancellationToken();
    addTearDown(lifetime.cancel);
    server = await AgentServer.start(directory: '${root.path}/server', port: 0,
      configPath: '${root.path}/config.yaml', skillsHome: root.path, telemetry: false);
    addTearDown(server.close);
    // Use the network boundary even though the fixture shares this filesystem.
    client = await AgentClient.connect(server.uri, sharedFilesystem: false);
    addTearDown(client.close);
  });

  test('browse uses server paths and create returns an inspectable Git repository', () async {
    await Directory('${root.path}/folder with spaces λ').create();
    await File('${root.path}/folder-file').writeAsString('not a directory');
    final folders = await client.browseProjectFolders('${root.path}/folder', cancellation: lifetime);
    expect((folders['folders'] as List).map((value) => value['name']), ['folder with spaces λ']);
    final home = await client.browseProjectFolders('~/', cancellation: lifetime);
    expect(home['directory'], Platform.environment['HOME']);
    final destination = '${root.path}/nested/new project';
    final receipt = await client.prepareProjectFolder('create', destination,
      operationId: newId(), cancellation: lifetime);
    expect(receipt['path'], destination);
    final workspace = await client.inspectWorkspace(destination, cancellation: lifetime);
    expect(workspace['available'], true);
    expect(workspace['repositoryRoot'], await Directory(destination).resolveSymbolicLinks());
    expect(await git(destination, ['rev-parse', '--is-inside-work-tree']), 'true');
  });

  test('clone transfers contents and preserves an existing destination on retry or failure', () async {
    final source = await Directory('${root.path}/source repo').create();
    await git(source.path, ['init']);
    await File('${source.path}/tracked.txt').writeAsString('cloned contents\n');
    await git(source.path, ['add', '.']);
    await git(source.path, ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Initial']);
    final destination = '${root.path}/checkout λ with spaces';
    final progress = <Json>[];
    final id = newId();
    final subscription = client.events.stream.listen((event) {
      if (event['method'] == 'workspace.progress' && event['params']?['operationId'] == id) {
        progress.add(jsonObject(event['params']));
      }
    });
    addTearDown(subscription.cancel);
    await client.prepareProjectFolder('clone', destination, remoteUrl: source.path,
      operationId: id, cancellation: lifetime);
    expect(await File('$destination/tracked.txt').readAsString(), 'cloned contents\n');
    expect(await git(destination, ['rev-parse', 'HEAD']), await git(source.path, ['rev-parse', 'HEAD']));
    expect(progress, isNotEmpty);
    await expectLater(client.prepareProjectFolder('clone', destination, remoteUrl: source.path,
      operationId: newId(), cancellation: lifetime), throwsA(isA<StateError>()));
    expect(await File('$destination/tracked.txt').readAsString(), 'cloned contents\n');
    final failed = '${root.path}/failed';
    await expectLater(client.prepareProjectFolder('clone', failed, remoteUrl: '${root.path}/missing',
      operationId: newId(), cancellation: lifetime), throwsA(isA<StateError>()));
    expect(await Directory(failed).exists(), false);
    expect(await root.list().where((entry) => entry.path.contains('.happen-project-')).toList(), isEmpty);
  });

  test('cancelling a clone over WebSocket stops Git and removes its staging folder', () async {
    final arrived = Completer<void>(), release = Completer<void>();
    final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => remote.close(force: true));
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final requests = remote.listen((request) async {
      if (!arrived.isCompleted) arrived.complete();
      await release.future;
      try { request.response.statusCode = 404; await request.response.close(); }
      on IOException { /* Cancellation closes Git's connection. */ }
    });
    addTearDown(requests.cancel);
    final cancellation = CancellationToken();
    addTearDown(cancellation.cancel);
    final destination = '${root.path}/cancelled';
    final clone = client.prepareProjectFolder('clone', destination,
      remoteUrl: 'http://127.0.0.1:${remote.port}/repo.git', operationId: newId(), cancellation: cancellation);
    final rejected = expectLater(clone, throwsA(isA<CancelledException>()));
    await arrived.future.timeout(const Duration(seconds: 10));
    cancellation.cancel();
    await rejected;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while ((await root.list().where((entry) => entry.path.contains('.happen-project-')).toList()).isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(await Directory(destination).exists(), false);
    expect(await root.list().where((entry) => entry.path.contains('.happen-project-')).toList(), isEmpty);
    expect((await client.browseProjectFolders('${root.path}/', cancellation: lifetime))['directory'], root.path);
  });
}
