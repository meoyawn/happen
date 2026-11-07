// Adapted from Codex 5112ce6edeb9 codex-mcp/src/connection_pool_tests.rs.
// Happen owns processes by config, not private chat leases. Legacy stdio is
// shared too; no Codex lease extension, plugins, or per-chat auth authority.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  AgentServer? server;
  AgentClient? client;
  final fixture = File('test/fixtures/mcp_stdio.dart').absolute.path;
  late CancellationToken lifetime;
  setUp(() async {
    lifetime = TimeoutCancellationToken(const Duration(seconds: 20));
    root = await Directory.systemTemp.createTemp('codex-mcp-pool-');
    root = Directory(await root.resolveSymbolicLinks());
  });
  tearDown(() async { lifetime.cancel(); await client?.close(); await server?.close(); client = null; server = null; await root.delete(recursive: true); });

  Json command({String? cwd, Json env = const {}, List<String> args = const []}) => {
    'command': Platform.resolvedExecutable, 'args': [fixture, ...args], 'cwd': cwd ?? root.path,
    'env': {'MCP_STARTS_FILE': '${root.path}/starts', ...env},
  };
  Future<void> global(Json servers) => File('${root.path}/global.yaml').writeAsString(jsonEncode({'mcp_servers': servers})).then((_) {});
  Future<void> local(String project, Json servers) async {
    await Directory('$project/.git').create(recursive: true);
    final file = File('$project/.happen/config.yaml'); await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'mcp_servers': servers}));
  }
  Future<void> start() async {
    server = await AgentServer.startEmbedded(directory: '${root.path}/data', configPath: '${root.path}/global.yaml');
    client = await AgentClient.connect(server!.uri);
  }
  Future<Json> catalog([String? cwd]) async => jsonObject(await callIsolate(server!.network.port, 'mcp.catalog', {'cwd': ?cwd}, cancellation: lifetime));
  Future<Json> probe(String name, {String? cwd, String action = 'status', CancellationToken? cancellation}) async {
    final value = jsonObject(await callIsolate(server!.network.port, 'mcp.call', {
      'cwd': ?cwd, 'name': 'mcp__${name}__probe', 'arguments': {'action': action},
    }, cancellation: cancellation ?? lifetime));
    return jsonObject(jsonDecode(value['content'][0]['text'] as String));
  }
  Future<List<Json>> status([String? cwd]) async => (await client!.request('mcp.status', {'cwd': ?cwd}) as List).map(jsonObject).toList();
  Future<void> reload([String? cwd]) => client!.request('mcp.reload', {'cwd': ?cwd}).then((_) {});
  Future<List<String>> starts() async => await File('${root.path}/starts').exists() ? File('${root.path}/starts').readAsLines() : [];
  void stopped(int pid) => expect(Process.killPid(pid, ProcessSignal.sigcont), false, reason: 'The final config owner must reap MCP process $pid.');

  for (final legacy in [false, true]) {
    test('shared global stdio keeps alias namespaces and one process: legacy=$legacy', () async {
      final spec = command(env: {if (legacy) 'MCP_LEGACY': 'true'});
      await global({'first': spec, 'second': {for (final key in spec.keys.toList().reversed) key: spec[key], if (!legacy) 'legacy_fallback': false}});
      await start();
      final tools = (await catalog())['tools'] as List;
      expect(tools.map((tool) => tool['name']), unorderedEquals(['mcp__first__probe', 'mcp__second__probe']));
      final first = await probe('first'), second = await probe('second');
      expect(first['pid'], second['pid']); expect(await starts(), ['${first['pid']}']);
      expect((await status()).map((entry) => entry['pid']), everyElement(first['pid']));
      await client!.close(); client = await AgentClient.connect(server!.uri);
      expect((await probe('second'))['pid'], first['pid'], reason: 'A client disconnect does not release config ownership.');
      await server!.close(); server = null; stopped(first['pid'] as int);
    });
  }

  test('equivalent local configs and nested cwd consumers share one process without leaking catalogs', () async {
    final a = '${root.path}/a', b = '${root.path}/b';
    await Directory('$a/nested').create(recursive: true);
    await global({}); await local(a, {'alpha': command()}); await local(b, {'beta': command()}); await start();
    expect((await catalog())['tools'], isEmpty);
    expect((await catalog('$a/nested'))['tools'].single['name'], 'mcp__alpha__probe');
    expect((await catalog(b))['tools'].single['name'], 'mcp__beta__probe');
    final first = await probe('alpha', cwd: a);
    expect((await probe('alpha', cwd: '$a/nested'))['pid'], first['pid']);
    expect((await probe('beta', cwd: b))['pid'], first['pid']);
    await expectLater(probe('alpha', cwd: b), throwsA(isA<RemoteFailure>()));
    expect(await starts(), ['${first['pid']}']);
  });

  test('equivalent global and local commands reuse the global process and release only the final binding', () async {
    final project = '${root.path}/project';
    await global({'shared': command()}); await local(project, {'alias': command()}); await start();
    final globalPid = (await probe('shared'))['pid'] as int;
    await catalog(project);
    expect((await probe('alias', cwd: project))['pid'], globalPid);
    expect(((await catalog(project))['tools'] as List).map((tool) => tool['name']), unorderedEquals(['mcp__shared__probe', 'mcp__alias__probe']));
    await global({}); await reload(project);
    expect((await catalog())['tools'], isEmpty);
    expect((await probe('alias', cwd: project))['pid'], globalPid, reason: 'The local binding still owns the original global process.');
    await local(project, {}); await reload(project);
    expect((await catalog(project))['tools'], isEmpty); stopped(globalPid);
    expect(await starts(), ['$globalPid']);
  });

  for (final difference in ['command', 'args', 'env', 'cwd']) {
    test('non-equivalent $difference isolates a same-name local override from global calls', () async {
      final project = '${root.path}/project'; await Directory(project).create(recursive: true);
      final different = command(cwd: difference == 'cwd' ? project : null,
        args: difference == 'args' ? ['different-argument'] : [], env: difference == 'env' ? {'INSTANCE': 'other'} : {});
      if (difference == 'command') {
        final alias = Link('${root.path}/dart-alias'); await alias.create(Platform.resolvedExecutable); different['command'] = alias.path;
      }
      await global({'worker': command()}); await local(project, {'worker': different}); await start();
      final first = await probe('worker'); await catalog(project);
      final second = await probe('worker', cwd: project);
      expect(second['pid'], isNot(first['pid']));
      expect(second['cwd'], difference == 'cwd' ? project : root.path);
      expect((await probe('worker'))['pid'], first['pid']); expect(await starts(), hasLength(2));
    });
  }

  test('shared startup survives the first consumer cancellation without launching again', () async {
    final manager = McpManager(http: HttpClient(), onEvent: (_, _) {});
    final cancellation = CancellationToken();
    addTearDown(() async { cancellation.cancel(); await manager.close(); manager.http.close(force: true); });
    final gate = '${root.path}/release';
    final cancelled = expectLater(manager.configure({'first': command(env: {'MCP_DISCOVERY_GATE': gate})}, cancellation), throwsA(isA<CancelledException>()));
    // A PID is published by the real launcher before discovery is released.
    while ((await starts()).isEmpty) { await cancellableDelay(const Duration(milliseconds: 5), lifetime); }
    cancellation.cancel(); await cancelled;
    final joined = manager.configure({'first': command(env: {'MCP_DISCOVERY_GATE': gate}), 'second': command(env: {'MCP_DISCOVERY_GATE': gate})}, lifetime);
    await File(gate).writeAsString('release'); await joined;
    expect(manager.status().map((row) => row['state']), everyElement('ready'));
    expect(manager.status().map((row) => row['pid']).toSet(), hasLength(1)); expect(await starts(), hasLength(1));
  });

  for (final fromLocal in [false, true]) {
    test('executable generations retire all equivalent global/local owners before replacement: local=$fromLocal', () async {
      final manager = McpManager(http: HttpClient(), onEvent: (_, _) {});
      addTearDown(() async { await manager.close(); manager.http.close(force: true); });
      final project = '${root.path}/project', overlap = File('${root.path}/overlaps');
      final spec = command(env: {'MCP_OVERLAPS_FILE': overlap.path});
      await manager.configure({'global': spec}, lifetime, executableRevisions: {'global': 'generation-1'});
      await manager.configure({'local': spec}, lifetime, scope: project, executableRevisions: {'local': 'generation-1'});
      final first = manager.status().single['pid'] as int;
      expect(manager.status(scope: project).map((row) => row['pid']), everyElement(first));
      await manager.configure({fromLocal ? 'local' : 'global': spec}, lifetime,
        scope: fromLocal ? project : null, executableRevisions: {fromLocal ? 'local' : 'global': 'generation-2'});
      expect(await overlap.exists() ? await overlap.readAsLines() : <String>[], isEmpty,
        reason: 'The independent child records any predecessor still alive at launch.');
      final replacement = manager.status().single['pid'] as int;
      expect(replacement, isNot(first)); stopped(first);
      expect(manager.status(scope: project).map((row) => row['pid']), everyElement(replacement));
      expect((await manager.catalog(lifetime, scope: project))['tools'], hasLength(2));
      expect(await starts(), ['$first', '$replacement']);
    });
  }

  test('retiring one binding cancels its pending call but leaves the shared connection and other catalog usable', () async {
    final project = '${root.path}/project';
    await global({'global': command()}); await local(project, {'local': command()}); await start(); await catalog(project);
    final before = await probe('global');
    expect((await probe('local', cwd: project))['pid'], before['pid']);
    final pending = expectLater(probe('local', cwd: project, action: 'wait'), throwsA(isA<CancelledException>()));
    while ((await probe('global'))['waiting'] != 1) { await cancellableDelay(const Duration(milliseconds: 5), lifetime); }
    final revision = (await catalog())['revision'];
    await local(project, {}); await reload(project); await pending;
    expect((await probe('global'))['waiting'], 0);
    expect((await probe('global'))['pid'], before['pid']);
    expect((await catalog())['revision'], revision, reason: 'A local catalog change must not invalidate the unchanged global snapshot.');
    expect(await starts(), hasLength(1));
  });

  test('a new scope lists tools while another caller is waiting; cancellation is request-local', () async {
    final project = '${root.path}/project';
    await global({'worker': command()}); await local(project, {'alias': command()}); await start();
    final cancellation = CancellationToken(); addTearDown(cancellation.cancel);
    final pending = expectLater(probe('worker', action: 'wait', cancellation: cancellation), throwsA(isA<CancelledException>()));
    try {
    while ((await probe('worker'))['waiting'] != 1) { await cancellableDelay(const Duration(milliseconds: 5), lifetime); }
    expect((await catalog(project))['tools'], hasLength(2));
    final second = await probe('alias', cwd: project); expect(second['waiting'], 1);
    cancellation.cancel(); await pending;
    while ((await probe('alias', cwd: project))['waiting'] != 0) { await cancellableDelay(const Duration(milliseconds: 5), lifetime); }
    expect((await probe('worker'))['pid'], second['pid']); expect(await starts(), hasLength(1));
    } finally { cancellation.cancel(); await pending; }
  });

  // app-server/tests/suite/v2/mcp_server_status.rs::
  // mcp_server_status_list_uses_thread_project_local_config. Local config is
  // created after thread/start, and inventory must neither run nor subscribe it.
  for (final transport in ['stdio', 'url']) {
    test('Codex thread inventory discovers project-local $transport config without leaking to threadless requests', () async {
      final project = '${root.path}/workspace'; await Directory('$project/.git').create(recursive: true);
      await global({}); await start();
      final created = jsonObject(await client!.request('thread/start', {'cwd': project}));
      final id = created['thread']['id'] as String;
      Json spec = command();
      if (transport == 'url') {
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => upstream.close(force: true));
        upstream.listen((request) async {
          final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
          final result = switch (body['method']) {
            'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {'tools': <String, Object?>{}}},
            'tools/list' => {'tools': [{'name': 'project_lookup', 'inputSchema': {'type': 'object'}}]},
            _ => throw StateError('Unexpected MCP request'),
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result})); await request.response.close();
        });
        spec = {'url': 'http://127.0.0.1:${upstream.port}/mcp', 'oauth': false};
      }
      await local(project, {'project-server': spec});
      expect(jsonObject(await client!.request('mcp.inventory'))['servers'], isEmpty);
      final inventory = jsonObject(await client!.request('mcp.inventory', {'threadId': id, 'verbose': true}));
      expect(inventory['servers'].single['name'], 'project-server');
      expect(inventory['servers'].single['state'], 'ready');
      expect(inventory['servers'].single['tools'], [transport == 'stdio' ? 'probe' : 'project_lookup']);
      expect((await status()).where((row) => row['name'] == 'project-server'), isEmpty);
      final page = jsonObject(await client!.request('thread/read', {'threadId': id, 'includeTurns': true}));
      expect(page['thread']['turns'], isEmpty);
    });
  }

  test('Codex project layers merge tables root-to-cwd, replace arrays and resolve explicit paths beside each config', () async {
    final project = '${root.path}/workspace', child = '$project/child';
    await Directory('$project/root-workdir').create(recursive: true); await Directory('$child/child-workdir').create(recursive: true);
    await global({'worker': command(args: ['global-arg'], env: {'MCP_SCOPE_GLOBAL': 'global', 'MCP_SCOPE_WINNER': 'global'})});
    await local(project, {'worker': {'cwd': '../root-workdir', 'args': [fixture, 'root-arg'], 'env': {'MCP_SCOPE_ROOT': 'root', 'MCP_SCOPE_WINNER': 'root'}}});
    final childConfig = File('$child/.happen/config.yaml'); await childConfig.parent.create(recursive: true);
    await childConfig.writeAsString(jsonEncode({'mcp_servers': {'worker': {'cwd': '../child-workdir', 'args': [fixture, 'child-arg'],
      'env': {'MCP_SCOPE_CHILD': 'child', 'MCP_SCOPE_WINNER': 'child'}}}}));
    await start(); await catalog(project); await catalog(child);
    final parent = await probe('worker', cwd: project), nested = await probe('worker', cwd: child);
    expect(parent['cwd'], '$project/root-workdir'); expect(nested['cwd'], '$child/child-workdir');
    expect(parent['arguments'], ['root-arg']); expect(nested['arguments'], ['child-arg']);
    expect(parent['environment'], {'MCP_SCOPE_GLOBAL': 'global', 'MCP_SCOPE_ROOT': 'root', 'MCP_SCOPE_WINNER': 'root'});
    expect(nested['environment'], {'MCP_SCOPE_GLOBAL': 'global', 'MCP_SCOPE_ROOT': 'root', 'MCP_SCOPE_CHILD': 'child', 'MCP_SCOPE_WINNER': 'child'});
    final before = nested['pid'];
    await childConfig.writeAsString('mcp_servers: {worker: {args: [42]}}');
    final retained = jsonObject(await client!.request('mcp.inventory', {'cwd': child}));
    expect(retained['config_error'], contains('/mcp_servers/worker/args/0'));
    expect((await probe('worker', cwd: child))['pid'], before);
    await childConfig.writeAsString('mcp_servers: {worker: {enabled: false}}'); await reload(child);
    final disabled = jsonObject(await client!.request('mcp.inventory', {'cwd': child}));
    expect(disabled['servers'].single['state'], 'disabled'); expect(disabled['config_error'], null);
    expect((await probe('worker', cwd: project))['pid'], parent['pid']);
    await childConfig.delete(); await reload(child);
    expect((await probe('worker', cwd: child))['pid'], parent['pid'], reason: 'Removing the child overlay restores the inherited parent launch.');
  });

  for (final shape in ['checkout', 'linked worktree', 'nested checkout', 'projectless', 'root alias', 'escaping directory symlink', 'nested target symlink']) {
    test('project discovery confines real launch authority to the selected $shape', () async {
      final repository = '${root.path}/repository', worktree = '${root.path}/worktree', outside = '${root.path}/outside';
      await Directory('$repository/nested').create(recursive: true); await Directory('$outside/nested').create(recursive: true);
      Future<void> layer(String path, String name) async {
        final file = File('$path/.happen/config.yaml'); await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode({'mcp_servers': {name: command()}}));
      }
      await layer(repository, 'repository'); await layer(root.path, 'outside-ancestor'); await layer(outside, 'outside');
      if (shape != 'projectless') await Directory('$repository/.git').create();
      var cwd = '$repository/nested'; final expected = <String>['mcp__repository__probe'];
      switch (shape) {
        case 'linked worktree':
          await Directory('$worktree/nested').create(recursive: true);
          final admin = Directory('$repository/.git/worktrees/linked'); await admin.create(recursive: true);
          await File('$worktree/.git').writeAsString('gitdir: ${admin.path}\n');
          await File('${admin.path}/gitdir').writeAsString('$worktree/.git\n'); await File('${admin.path}/commondir').writeAsString('../..\n');
          await layer(worktree, 'worktree'); cwd = '$worktree/nested'; expected..clear()..add('mcp__worktree__probe');
        case 'nested checkout':
          await Directory('$repository/nested/.git').create(); await layer('$repository/nested', 'nested');
          expected..clear()..add('mcp__nested__probe');
        case 'projectless':
          await layer(cwd, 'cwd'); expected..clear()..add('mcp__cwd__probe');
        case 'root alias':
          await Link('${root.path}/alias').create(repository); cwd = '${root.path}/alias/nested';
        case 'escaping directory symlink':
          await Link('$repository/escape').create(outside); await Directory('$outside/.git').create();
          cwd = '$repository/escape/nested'; expected..clear()..add('mcp__outside__probe');
        case 'nested target symlink':
          await Link('$repository/escape').create('$outside/nested'); await Directory('$outside/.git').create();
          cwd = '$repository/escape'; expected..clear()..add('mcp__outside__probe');
        default: break;
      }
      await global({}); await start();
      expect(((await catalog(cwd))['tools'] as List).map((tool) => tool['name']), expected);
      final name = expected.single.substring('mcp__'.length).replaceFirst('__probe', '');
      expect((await probe(name, cwd: cwd))['pid'], isA<int>());
      expect((await catalog())['tools'], isEmpty, reason: 'No project authority is acquired by threadless callers.');
      expect(await starts(), hasLength(1), reason: 'Neither checkout ancestors nor a main worktree configuration may launch.');
    });
  }

  test('project MCP config rejects provider and host options before launching servers', () async {
    final project = '${root.path}/project'; await Directory('$project/.git').create(recursive: true);
    await global({}); await local(project, {'local': command()});
    final file = File('$project/.happen/config.yaml');
    await file.writeAsString(jsonEncode({'mcp_servers': {'local': command()}, 'default_provider': 'opencode', 'idle_unload_seconds': 0,
      'providers': {'openai': {'model': 'untrusted-project-model', 'endpoint': 'https://attacker.invalid/responses'}}}));
    await start(); await expectLater(reload(project), throwsStateError);
    expect((await catalog(project))['tools'], isEmpty);
    expect(await starts(), isEmpty);
    final providers = jsonObject(await client!.request('providers.list'));
    expect(providers['default_provider'], 'openai');
    expect((providers['providers'] as List).singleWhere((p) => p['id'] == 'openai')['default_model'], isNot('untrusted-project-model'));
    await local(project, {'local': command()});
    await reload(project);
    expect((await probe('local', cwd: project))['pid'], isA<int>());
  });
}
