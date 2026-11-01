import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  for (final lab in ['openai', 'opencode']) {
    test('$lab cancels foreground tools and preserves task sessions until hibernation, archive, or shutdown', () async {
      final root = await Directory.systemTemp.createTemp('tool-cancellation-');
      final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      AgentServer? server;
      AgentClient? client;
      addTearDown(() async {
        await client?.close();
        await server?.close();
        await provider.close(force: true);
        await root.delete(recursive: true);
      });
      for (final name in ['a', 'b']) { await Directory('${root.path}/$name').create(); }
      await File('${root.path}/session.sh').writeAsString(r'''
echo $$ > session.pid
while read value; do printf 'received:%s\n' "$value"; done
''');
      await File('${root.path}/foreground.sh').writeAsString(r'''
echo $$ > foreground.pid
/bin/sh -c 'echo $$ > child.pid; sleep 60' &
wait
''');
      await File('${root.path}/wait-session.sh').writeAsString('echo \$\$ > wait-session.pid\nread value\n');
      await File('${root.path}/auth.json').writeAsString(jsonEncode({
        'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }));
      await File('${root.path}/opencode-auth.json').writeAsString(jsonEncode({
        'version': 1, 'type': 'opencode', 'server': 'https://opencode.ai/console',
        'access_token': 'fixture', 'refresh_token': 'fixture', 'org_id': 'fixture',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }));
      await File('${root.path}/config.yaml').writeAsString(jsonEncode({
        'default_provider': lab,
        'providers': {'opencode': {'endpoint': 'http://127.0.0.1:${provider.port}/inference/openai/v1'}},
        'mcp_servers': {'local': {'command': Platform.resolvedExecutable,
          'args': [File('test/fixtures/mcp_stdio.dart').absolute.path], 'legacy_fallback': false}},
      }));
      int? session;
      provider.listen((request) async {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        final input = (body[lab == 'openai' ? 'input' : 'messages'] as List).map(jsonObject).toList();
        final user = input.lastIndexWhere((item) => item['role'] == 'user');
        final prompt = input[user]['content'];
        final called = input.skip(user + 1).any((item) => lab == 'openai'
          ? ['custom_tool_call_output', 'function_call_output'].contains(item['type']) : item['role'] == 'tool');
        String? name;
        Object? arguments;
        if (!called && prompt == 'mcp') {
          name = lab == 'openai' ? 'exec' : 'execute';
          arguments = lab == 'openai'
            ? 'await Promise.all([tools.mcp__local__probe({action: "wait"}), tools.mcp__local__probe({action: "wait"})]);'
            : {'code': 'return await Promise.all([tools.local.probe({action: "wait"}), tools.local.probe({action: "wait"})]);'};
        } else if (!called && ['spin', 'start-wait'].contains(prompt)) {
          name = lab == 'openai' ? 'exec' : 'execute';
          final code = prompt == 'spin' ? 'while (true) {}'
            : 'await tools.exec_command({cmd: "/bin/sh ../wait-session.sh", shell: "/bin/sh", login: false, yield_time_ms: 30000});';
          arguments = lab == 'openai' ? code : {'code': code};
        } else if (!called && ['start', 'short', 'session'].contains(prompt)) {
          if (lab == 'openai') {
            name = 'exec';
            arguments = prompt == 'start'
              ? 'text(await tools.exec_command({cmd: "/bin/sh ../session.sh", shell: "/bin/sh", login: false, yield_time_ms: 250}));'
              : prompt == 'short'
                ? 'text(await tools.shell_command({command: "/bin/sh ../foreground.sh", shell: "/bin/sh", login: false, timeout_ms: 60000}));'
                : 'text(await tools.write_stdin({session_id: $session, chars: "hello\\n", yield_time_ms: 250}));';
          } else {
            name = 'shell';
            arguments = {
              'command': prompt == 'start' ? '/bin/sh ../session.sh'
                : prompt == 'short' ? '/bin/sh ../foreground.sh' : '/bin/kill -0 (/bin/cat session.pid)',
              if (prompt == 'start') 'background': true,
            };
          }
        }
        request.response.headers.contentType = ContentType('text', 'event-stream');
        if (lab == 'openai') {
          request.response.write('data: ${jsonEncode({
            'type': 'response.completed', 'response': {
              'status': 'completed', 'usage': {'input_tokens': 100, 'output_tokens': 10},
              'output': [if (name != null) {
                'type': 'custom_tool_call', 'namespace': 'functions', 'name': name, 'input': arguments, 'call_id': newId(),
              } else {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'ready'}]}],
            },
          })}\n\n');
        } else {
          request.response.write('data: ${jsonEncode({'choices': [{'index': 0, 'delta': name == null
            ? {'content': 'ready'} : {'tool_calls': [{'index': 0, 'id': newId(), 'type': 'function',
              'function': {'name': name, 'arguments': jsonEncode(arguments)}}]},
            'finish_reason': name == null ? 'stop' : 'tool_calls'}]})}\n\n');
          request.response.write('data: [DONE]\n\n');
        }
        await request.response.close();
      });
      server = await AgentServer.startEmbedded(directory: root.path,
        configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
      client = await AgentClient.connect(server.uri);
      Future<Json> turn(String method, Json params) async {
        final terminal = client!.events.stream.firstWhere((event) =>
          ['turn.completed', 'turn.cancelled', 'turn.failed'].contains(event['type']));
        await client.request(method, params);
        final event = await terminal.timeout(const Duration(seconds: 10));
        expect(event['type'], 'turn.completed', reason: event.toString());
        return event;
      }
      final first = await turn('task.start', {'cwd': '${root.path}/a', 'prompt': 'start'});
      final id = first['task_id'] as String;
      final a = File('${root.path}/a/session.pid'), b = File('${root.path}/b/session.pid');
      await _until(() => a.exists());
      expect(await _alive(a), isTrue, reason: 'A task-owned process must survive turn completion');
      if (lab == 'openai') {
        final history = await client.request('history.page', {'task_id': id}) as List;
        session = history.singleWhere((event) => event['type'] == 'host_tool.completed')['data']['output']['session_id'] as int;
      }
      await turn('task.send', {'task_id': id, 'prompt': 'session'});
      if (lab == 'openai') {
        final history = await client.request('history.page', {'task_id': id}) as List;
        expect(history.where((event) => event['type'] == 'host_tool.completed').last['data']['output']['output'], 'received:hello\n');
      }
      final second = await turn('task.start', {'cwd': '${root.path}/b', 'prompt': 'start'});
      await _until(() => b.exists());
      final probeToken = CancellationToken(), siblingToken = CancellationToken();
      addTearDown(probeToken.cancel); addTearDown(siblingToken.cancel);
      Future<Json> probe() async {
        final response = jsonObject(await callIsolate(server!.network.port, 'mcp.call',
          {'name': 'mcp__local__probe', 'arguments': {'action': 'inspect'}}, cancellation: probeToken));
        return jsonObject(jsonDecode(response['content'][0]['text'] as String));
      }
      final process = (await probe())['pid'];
      final sibling = expectLater(callIsolate(server.network.port, 'mcp.call', {
        'task_id': second['task_id'], 'name': 'mcp__local__probe', 'arguments': {'action': 'wait'},
      }, cancellation: siblingToken), throwsA(isA<CancelledException>()));
      await _until(() async => (await probe())['waiting'] == 1);
      for (final steer in [true, false]) {
        final terminal = client.events.stream.firstWhere((event) => event['task_id'] == id &&
          ['turn.completed', 'turn.cancelled', 'turn.failed'].contains(event['type']));
        await client.request('task.send', {'task_id': id, 'prompt': 'mcp'});
        await _until(() async => (await probe())['waiting'] == 3);
        if (steer) {
          await client.request('task.send', {'task_id': id, 'prompt': 'continued', 'delivery': 'steer'});
        } else {
          await client.request('task.cancel', {'task_id': id});
        }
        expect((await terminal.timeout(const Duration(seconds: 5)))['type'], steer ? 'turn.completed' : 'turn.cancelled');
        await _until(() async => (await probe())['waiting'] == 1);
        expect((await probe())['pid'], process, reason: 'Cancellation must preserve the shared MCP server and sibling call');
      }
      siblingToken.cancel(); await sibling;
      await _until(() async => (await probe())['waiting'] == 0);
      for (final steer in [true, false]) {
        final started = client.events.stream.firstWhere((event) => event['task_id'] == id && event['type'] == 'tool.started');
        final terminal = client.events.stream.firstWhere((event) => event['task_id'] == id &&
          ['turn.completed', 'turn.cancelled', 'turn.failed'].contains(event['type']));
        await client.request('task.send', {'task_id': id, 'prompt': 'spin'});
        await started;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (steer) {
          await client.request('task.send', {'task_id': id, 'prompt': 'continued', 'delivery': 'steer'});
        } else {
          await client.request('task.cancel', {'task_id': id});
        }
        expect((await terminal.timeout(const Duration(seconds: 5)))['type'], steer ? 'turn.completed' : 'turn.cancelled');
      }
      for (final steer in [true, false]) {
        final foreground = File('${root.path}/a/foreground.pid'), child = File('${root.path}/a/child.pid');
        if (await foreground.exists()) await foreground.delete();
        if (await child.exists()) await child.delete();
        final terminal = client.events.stream.firstWhere((event) => event['task_id'] == id &&
          ['turn.completed', 'turn.cancelled', 'turn.failed'].contains(event['type']));
        await client.request('task.send', {'task_id': id, 'prompt': 'short'});
        await _until(() => child.exists());
        expect(await _alive(foreground), isTrue);
        if (steer) {
          await client.request('task.send', {'task_id': id, 'prompt': 'continued', 'delivery': 'steer'});
        } else {
          await client.request('task.cancel', {'task_id': id});
        }
        final event = await terminal.timeout(const Duration(seconds: 5));
        expect(event['type'], steer ? 'turn.completed' : 'turn.cancelled', reason: event.toString());
        await _until(() async => !await _alive(foreground) && !await _alive(child));
        expect(await _alive(a), isTrue);
        expect(await _alive(b), isTrue);
      }
      final waitingSession = File('${root.path}/a/wait-session.pid');
      if (lab == 'openai') {
        final terminal = client.events.stream.firstWhere((event) => event['task_id'] == id &&
          ['turn.completed', 'turn.cancelled', 'turn.failed'].contains(event['type']));
        await client.request('task.send', {'task_id': id, 'prompt': 'start-wait'});
        await _until(() => _alive(waitingSession));
        await client.request('task.send', {'task_id': id, 'prompt': 'continued', 'delivery': 'steer'});
        expect((await terminal.timeout(const Duration(seconds: 5)))['type'], 'turn.completed');
        expect(await _alive(waitingSession), isTrue, reason: 'Cancelling the initial exec wait must preserve its task-owned process');
      }
      Future<void> stopWith(String method) async {
        final child = File('${root.path}/a/child.pid');
        if (await child.exists()) await child.delete();
        final terminal = client!.events.stream.firstWhere((event) => event['task_id'] == id &&
          ['turn.completed', 'turn.cancelled', 'turn.failed'].contains(event['type']));
        await client.request('task.send', {'task_id': id, 'prompt': 'short'});
        await _until(() => _alive(child));
        await client!.request(method, {'task_id': id});
        expect((await terminal)['type'], 'turn.cancelled');
        expect(await _alive(child), isFalse);
      }
      await stopWith('task.hibernate');
      expect(await _alive(a), isFalse);
      if (lab == 'openai') expect(await _alive(waitingSession), isFalse);
      expect(await _alive(b), isTrue);
      await a.delete();
      await turn('task.send', {'task_id': id, 'prompt': 'start'});
      await _until(() => a.exists());
      expect(await _alive(a), isTrue);
      await stopWith('task.archive');
      expect(await _alive(a), isFalse);
      expect(await _alive(b), isTrue);
      await client.request('task.cancel', {'task_id': second['task_id']});
      expect(await _alive(b), isTrue, reason: 'Stop does not hibernate a task');
      await client.close(); client = null;
      await server.close(); server = null;
      expect(await _alive(b), isFalse);
    });
  }
}

Future<bool> _alive(File file) async {
  if (!await file.exists()) return false;
  final id = (await file.readAsString()).trim();
  if (id.isEmpty) return false;
  final process = await Process.run('ps', ['-p', id, '-o', 'stat=']);
  final status = process.stdout.toString().trim();
  return process.exitCode == 0 && status.isNotEmpty && !status.startsWith('Z');
}

Future<void> _until(Future<bool> Function() condition) async {
  final elapsed = Stopwatch()..start();
  while (!await condition()) {
    if (elapsed.elapsed > const Duration(seconds: 3)) fail('Lifecycle condition did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
