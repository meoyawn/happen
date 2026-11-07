// Port of Codex 5112ce6edeb9 app-server/tests/suite/v2/turn_start.rs::
// command_execution_notifications_include_process_id, all three launch variants.
// These run agent-invoked CLI processes, not the desktop terminal UI.
// Cold replay additionally guards the live-to-canonical item boundary.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import '../../../test/support/thread_names.dart';

void main() {
  late Directory root;
  late HttpServer provider;
  late AgentServer server;
  late AgentClient client;
  final requests = <Json>[], events = <Json>[];
  late Json arguments;
  late StreamSubscription<Json> subscription;
  Future<AgentServer> launch() => AgentServer.start(directory: root.path, port: 0, skillsHome: root.path,
    configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
  Future<Json> read(String id) async => jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
  List<Json> items(Json page) => [for (final turn in page['thread']['turns'] as List)
    for (final item in turn['items'] as List)
      {for (final entry in jsonObject(item).entries) if (entry.key != 'order') entry.key: entry.value}];
  Json command(Json page) => items(page).singleWhere((item) => item['type'] == 'commandExecution');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-command-items-'); requests.clear(); events.clear();
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      if (await respondToThreadName(request, body)) return;
      requests.add(body);
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed',
        'output': [if (requests.length == 1) {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec',
          'call_id': 'cell', 'input': 'text(await tools.exec_command(${jsonEncode(arguments)}));'}
        else {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'done'}]}]}})}\n\n');
      await request.response.close();
    });
    server = await launch(); client = await AgentClient.connect(server.uri);
    subscription = client.events.stream.listen(events.add);
  });
  tearDown(() async {
    await subscription.cancel(); await client.close(); await server.close();
    await provider.close(force: true); await root.delete(recursive: true);
  });

  for (final variant in ['started', 'pipe_launch_failure', 'pty_launch_failure']) {
    test('command_execution_notifications_include_process_id: $variant', () async {
      final failed = variant != 'started';
      arguments = switch (variant) {
        'pipe_launch_failure' => {'cmd': 'echo unreachable', 'workdir': 'missing-work-directory', 'tty': false},
        'pty_launch_failure' => {'cmd': 'echo unreachable\u0000', 'tty': true, 'login': false},
        _ => {'cmd': '/bin/sh -c echo hi', 'yield_time_ms': 500},
      };
      final created = jsonObject(await client.request('thread/start', {'cwd': root.path})), id = created['thread']['id'] as String;
      final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == id);
      final startedTurn = jsonObject(await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'run a command'}]}));
      expect((await done.timeout(const Duration(seconds: 15)))['params']['turn']['status'], 'completed');
      final lifecycle = events.where((event) => event['params']?['item']?['type'] == 'commandExecution').toList();
      expect(lifecycle.map((event) => event['method']), ['item/started', 'item/completed'], reason: 'Exactly one command start and completion.');
      final started = jsonObject(lifecycle.first['params']['item']), completed = jsonObject(lifecycle.last['params']['item']);
      expect(started['type'], 'commandExecution'); expect(started['status'], 'inProgress');
      expect(started['processId'] == null, failed);
      if (!failed) expect(started['processId'], isA<String>().having((value) => int.tryParse(value), 'numeric process ID', isNotNull));
      expect(completed['type'], 'commandExecution'); expect(completed['id'], started['id']);
      expect(completed['status'], isIn(['completed', 'failed']));
      if (failed) {
        expect([completed['status'], completed['exitCode'], completed['durationMs']], ['failed', -1, 0]);
        expect(completed['aggregatedOutput'], startsWith('Failed to create unified exec process:'));
      } else if (completed['status'] == 'completed') {
        expect(completed['exitCode'], 0);
      } else { expect(completed['exitCode'], isNotNull); }
      expect(completed['processId'], started['processId']);
      expect(lifecycle.map((event) => event['params']['threadId']), everyElement(id));
      expect(lifecycle.map((event) => event['params']['turnId']), everyElement(startedTurn['turn']['id']));
      expect(requests, hasLength(2)); expect(command(await read(id)), completed);
      await subscription.cancel(); await client.close(); await server.close();
      server = await launch(); client = await AgentClient.connect(server.uri);
      subscription = client.events.stream.listen(events.add);
      expect(command(await read(id)), completed);
      expect(command(jsonObject(await client.request('thread/resume', {'threadId': id}))), completed);
      expect(requests, hasLength(2), reason: 'Read/resume must not execute the command again.');
    });
  }

  // core/tests/suite/unified_exec.rs::
  // unified_exec_full_lifecycle_with_background_end_event. A file gate replaces
  // the upstream sleep so the command necessarily outlives its first turn.
  // The catalog-selected Code Mode crosses the nested-call/runtime boundary.
  test('unified_exec_full_lifecycle_with_background_end_event', () async {
    arguments = {'cmd': "printf 'EARLY-OUTPUT'; while [ ! -f release-cli ]; do sleep 0.01; done; printf 'HELLO-FULL-LIFECYCLE'",
      'yield_time_ms': 1, 'login': false};
    final id = jsonObject(await client.request('thread/start', {'cwd': root.path}))['thread']['id'] as String;
    Future<Json> turn(String text) async {
      final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == id);
      await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': text}]});
      return jsonObject((await done.timeout(const Duration(seconds: 15)))['params']['turn']);
    }
    final first = await turn('exercise full unified exec lifecycle');
    expect(first['status'], 'completed');
    final starts = events.where((event) => event['method'] == 'item/started' && event['params']['item']['type'] == 'commandExecution').toList();
    expect(starts, hasLength(1));
    final started = jsonObject(starts.single['params']['item']), call = started['id'] as String;
    expect(started['processId'], isA<String>());
    expect(items(await read(id)).singleWhere((item) => item['id'] == call)['status'], 'inProgress');
    expect((await turn('another turn while the command remains live'))['status'], 'completed');
    expect(items(await read(id)).singleWhere((item) => item['id'] == call)['status'], 'inProgress');
    final ended = client.events.stream.firstWhere((event) => event['method'] == 'item/completed' && event['params']['item']['id'] == call);
    await File('${root.path}/release-cli').writeAsString('release');
    final end = await ended.timeout(const Duration(seconds: 10)), completed = jsonObject(end['params']['item']);
    expect(end['params']['turnId'], first['id']); expect(completed['processId'], started['processId']);
    expect(completed['status'], 'completed'); expect(completed['exitCode'], 0);
    expect(completed['aggregatedOutput'], 'EARLY-OUTPUTHELLO-FULL-LIFECYCLE');
    expect(events.where((event) => event['params']?['item']?['id'] == call).map((event) => event['method']), ['item/started', 'item/completed']);
    final page = await read(id);
    expect(page['thread']['turns'], hasLength(2));
    expect(items(page).singleWhere((item) => item['id'] == call), completed);
    expect((page['thread']['turns'][1]['items'] as List).where((item) => item['type'] == 'commandExecution'), isEmpty);
  });
}
