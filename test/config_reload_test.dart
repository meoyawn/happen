import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File file;
  AgentServer? server;
  AgentClient? client;
  final pids = <int>{};
  final fixture = File('test/fixtures/mcp_stdio.dart').absolute.path;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('config-reload-');
    file = File('${root.path}/settings/nested/config.yaml');
    pids.clear();
  });
  tearDown(() async {
    await client?.close();
    await server?.close();
    client = null;
    server = null;
    // Ensure a failing lifecycle assertion cannot leak a fixture subprocess.
    for (final pid in pids) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    await root.delete(recursive: true);
  });

  Future<void> start() async {
    server = await AgentServer.startEmbedded(
      directory: root.path,
      configPath: file.path,
    );
    client = await AgentClient.connect(server!.uri);
  }

  List<Json> servers(Object? raw) {
    final result = (raw as List).map(jsonObject).toList();
    pids.addAll(result.map((s) => s['pid']).whereType<int>());
    return result;
  }

  Future<List<Json>> status() async =>
      servers(await client!.request('mcp.status', {}));
  Future<Json> notice(String type, [bool Function(Json)? matches]) => client!
      .events
      .stream
      .firstWhere(
        (event) => event['type'] == type && (matches == null || matches(event)),
      )
      .timeout(const Duration(seconds: 10));

  Future<List<Json>> changed(
    Future<void> Function() edit,
    bool Function(List<Json>) matches,
  ) async {
    final ready = notice(
      'mcp.config.reloaded',
      (event) => matches(servers(event['data']['servers'])),
    );
    await edit();
    return servers((await ready)['data']['servers']);
  }

  Future<List<Json>> until(bool Function(List<Json>) matches) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final current = await status();
      if (matches(current)) return current;
      if (DateTime.now().isAfter(deadline)) {
        fail('MCP processes did not reach the expected state');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  String local(
    String name, {
    String? command,
    bool enabled = true,
    int delay = 0,
  }) =>
      '''
  $name:
    command: ${jsonEncode(command ?? Platform.resolvedExecutable)}
    args: ${jsonEncode([fixture])}
    env: {MCP_DISCOVERY_DELAY_MS: "$delay"}
    enabled: $enabled
    legacy_fallback: false
''';
  Future<void> write(String contents, {bool replace = false}) async {
    await file.parent.create(recursive: true);
    if (replace) {
      final temporary = File('${file.path}.new');
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(file.path);
    } else {
      await file.writeAsString(contents, flush: true);
    }
  }

  bool ready(List<Json> values, List<String> names) =>
      values.every((s) => s['state'] == 'ready') &&
      values.map((s) => s['name']).toSet().containsAll(names) &&
      values.length == names.length;
  int pidOf(List<Json> values, String name) =>
      values.singleWhere((s) => s['name'] == name)['pid'] as int;
  void stopped(int pid) => expect(
    Process.killPid(pid, ProcessSignal.sigcont),
    isFalse,
    reason: 'retired MCP process $pid must exit',
  );

  test('invalid manual reload preserves the live legacy MCP process', () async {
    final legacy = File('${root.path}/config.json');
    final config = {
      'command': Platform.resolvedExecutable,
      'args': [fixture],
      'legacy_fallback': false,
    };
    await legacy.writeAsString(
      jsonEncode({
        'mcp_servers': {'local': config},
      }),
    );
    await start();
    final initial = (await status()).single;
    expect(initial['state'], 'ready');
    await legacy.writeAsString(
      jsonEncode({
        'mcp_servers': {
          'local': {
            ...config,
            'args': [42],
          },
        },
      }),
    );
    await expectLater(client!.request('mcp.reload', {}), throwsStateError);
    final retained = (await status()).single;
    expect(retained['pid'], initial['pid']);
    expect(retained['state'], 'ready');
    final events = jsonObject(
      await client!.request('mcp.request', {
        'server': 'local',
        'method': 'events/list',
      }),
    );
    expect(events['events'].single['name'], 'tick');
  });

  test('watched YAML adds, replaces, disables, and removes shared processes', () async {
    await start();
    expect(await status(), isEmpty);
    final baseline = 'mcp_servers:\n${local('alpha')}${local('stable')}';
    final initial = await changed(
      () => write(baseline),
      (values) => ready(values, ['alpha', 'stable']),
    );
    final firstPid = pidOf(initial, 'alpha');
    final stablePid = pidOf(initial, 'stable');
    await client!.request('mcp.events.subscribe', {
      'server': 'stable',
      'name': 'tick',
      'mode': 'push',
    });

    final rejected = notice('mcp.config.error');
    await write('mcp_servers: {alpha: {command: dart, args: [42]}}');
    expect(
      (await rejected)['data']['error'],
      contains('/mcp_servers/alpha/args/0'),
    );
    expect(
      (await status()).map((s) => s['pid']),
      unorderedEquals([firstPid, stablePid]),
    );
    expect(await client!.request('mcp.events.subscriptions', {}), hasLength(1));
    await notice('mcp.event');

    await changed(
      () => write(baseline, replace: true),
      (values) => ready(values, ['alpha', 'stable']),
    );
    // Key order and comments do not change a process specification.
    await write(
      '# A comment\nmcp_servers:\n${local('stable')}${local('alpha')}',
      replace: true,
    );
    final unchanged = servers(await client!.request('mcp.reload', {}));
    expect(
      unchanged.map((s) => s['pid']),
      unorderedEquals([firstPid, stablePid]),
    );

    final alternate = '${root.path}/dart-alternate';
    await Link(alternate).create(Platform.resolvedExecutable);
    final replaced = await changed(
      () => write(
        'mcp_servers:\n${local('alpha', command: alternate)}${local('stable')}',
        replace: true,
      ),
      (values) =>
          ready(values, ['alpha', 'stable']) &&
          pidOf(values, 'alpha') != firstPid,
    );
    stopped(firstPid);
    expect(pidOf(replaced, 'stable'), stablePid);
    var alphaPid = pidOf(replaced, 'alpha');

    // Revert while the new process is still discovering. A cancelled apply must
    // not make equality with the old config skip the necessary reconciliation.
    await write(
      'mcp_servers:\n${local('alpha', delay: 6000)}${local('stable')}',
    );
    final starting = await until(
      (values) => values.any(
        (s) =>
            s['name'] == 'alpha' &&
            s['pid'] is int &&
            s['pid'] != alphaPid &&
            s['state'] == 'connecting',
      ),
    );
    final supersededPid = pidOf(starting, 'alpha');
    stopped(alphaPid);
    final reverted = await changed(
      () => write(
        'mcp_servers:\n${local('alpha', command: alternate)}${local('stable')}',
      ),
      (values) =>
          ready(values, ['alpha', 'stable']) &&
          pidOf(values, 'alpha') != supersededPid,
    );
    stopped(supersededPid);
    expect(pidOf(reverted, 'stable'), stablePid);
    alphaPid = pidOf(reverted, 'alpha');

    final missing = notice('mcp.config.error');
    await file.delete();
    expect((await missing)['data']['error'], contains('missing'));
    expect(
      (await status()).map((s) => s['pid']),
      unorderedEquals([stablePid, alphaPid]),
    );
    await changed(
      () => write(
        'mcp_servers:\n${local('alpha', enabled: false)}${local('stable')}',
        replace: true,
      ),
      (values) => ready(values, ['stable']),
    );
    stopped(alphaPid);
    expect((await status()).single['pid'], stablePid);
    await changed(() => write('mcp_servers: {}\n'), (values) => values.isEmpty);
    stopped(stablePid);
    expect(await client!.request('mcp.events.subscriptions', {}), isEmpty);

    final finalServers = await changed(
      () => write('mcp_servers:\n${local('alpha')}'),
      (values) => ready(values, ['alpha']),
    );
    await client!.close();
    client = null;
    await server!.close();
    server = null;
    stopped(pidOf(finalServers, 'alpha'));
  });

  test(
    'watched URL entries reconnect without owning remote server processes',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final probe = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() async {
        probe.close(force: true);
        await upstream.close(force: true);
      });
      upstream.listen((request) async {
        if (request.uri.path == '/health') {
          request.response.write('alive');
        } else {
          final body = jsonObject(
            jsonDecode(await utf8.decoder.bind(request).join()),
          );
          expect(request.headers.value('x-config'), 'fixture');
          final result = switch (body['method']) {
            'server/discover' => {
              'supportedVersions': ['2026-07-28'],
              'capabilities': {'events': {}},
            },
            'events/list' => {
              'events': [
                {
                  'name': request.uri.path,
                  'delivery': ['poll'],
                },
              ],
            },
            _ => throw StateError('Unexpected fixture request'),
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
          );
        }
        await request.response.close();
      });
      String configuration(String endpoint) =>
          '''
mcp_servers:
${local('local')}
  remote:
    url: http://127.0.0.1:${upstream.port}/$endpoint
    headers: {X-Config: fixture}
    legacy_fallback: false
''';
      await write(configuration('one'));
      await start();
      final initial = await status();
      expect(ready(initial, ['local', 'remote']), isTrue);
      expect(initial.singleWhere((s) => s['name'] == 'remote')['pid'], isNull);
      final localPid = pidOf(initial, 'local');
      Future<String> remoteEvent() async {
        final response = jsonObject(
          await client!.request('mcp.request', {
            'server': 'remote',
            'method': 'events/list',
          }),
        );
        return response['events'].single['name'] as String;
      }

      expect(await remoteEvent(), '/one');
      final updated = await changed(
        () => write(configuration('two'), replace: true),
        (values) => ready(values, ['local', 'remote']),
      );
      expect(pidOf(updated, 'local'), localPid);
      expect(updated.singleWhere((s) => s['name'] == 'remote')['pid'], isNull);
      expect(await remoteEvent(), '/two');
      final retained = await changed(
        () => write('mcp_servers:\n${local('local')}'),
        (values) => ready(values, ['local']),
      );
      expect(pidOf(retained, 'local'), localPid);
      await expectLater(remoteEvent(), throwsStateError);
      final request = await probe.getUrl(
        Uri.parse('http://127.0.0.1:${upstream.port}/health'),
      );
      expect(await utf8.decoder.bind(await request.close()).join(), 'alive');
    },
  );

  test(
    'startup reports the invalid field before starting the network owner',
    () async {
      await write('mcp_servers: {dart: {command: dart, args: false}}');
      await expectLater(
        start(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'field location',
            contains('/mcp_servers/dart/args'),
          ),
        ),
      );
    },
  );
}
