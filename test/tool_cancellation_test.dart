import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import 'support/thread_names.dart';

import 'support/openai_output.dart';
import 'support/thread.dart';

void main() {
  for (final lab in ['openai', 'opencode']) {
    test('$lab cancels foreground tools and preserves task sessions until idle unloading, archive, or shutdown', () async {
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
        'mcp_servers': {'local': {'command': Platform.resolvedExecutable,
          'args': [File('test/fixtures/mcp_stdio.dart').absolute.path], 'legacy_fallback': false}},
      }));
      int? session;
      final modelRequests = <Json>[];
      provider.listen((request) async {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        if (await respondToThreadName(request, body)) return;
        modelRequests.add(body);
        final input = (body[lab == 'openai' ? 'input' : 'messages'] as List).map(jsonObject).toList();
        final user = input.lastIndexWhere((item) => item['role'] == 'user');
        final prompt = openAIMessageText(input[user]);
        final called = input.skip(user + 1).any((item) => lab == 'openai'
          ? ['custom_tool_call_output', 'function_call_output'].contains(item['type']) : item['role'] == 'tool');
        String? name;
        Object? arguments;
        if (!called && prompt == 'sleep' && lab == 'openai') {
          name = 'sleep';
          arguments = {'duration_ms': 120000};
        } else if (!called && prompt == 'mcp') {
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
              'output': [if (name == 'sleep') {
                'type': 'function_call', 'namespace': 'clock', 'name': name, 'arguments': jsonEncode(arguments), 'call_id': newId(),
              } else if (name != null) {
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
        configPath: '${root.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses',
        openCodeEndpoint: 'http://127.0.0.1:${provider.port}/inference/openai/v1');
      client = await AgentClient.connect(server.uri);
      final id = await createThread(client, {'cwd': '${root.path}/a', 'provider': lab, 'config': {'thread_unload_delay_secs': 0}});
      Future<Json> terminal() async => jsonObject((await client!.events.stream.firstWhere((event) =>
        event['method'] == 'turn/completed' && event['params']['threadId'] == id)
          .timeout(const Duration(seconds: 10)))['params']['turn']);
      Future<Object?> send(String prompt, {bool steer = false}) => client!.request('turn/start', {
        'threadId': id, 'input': [{'type': 'text', 'text': prompt}], if (steer) 'delivery': 'steer',
      });
      Future<void> interrupt() async {
        final snapshot = jsonObject(await client!.request('thread/read', {'threadId': id, 'includeTurns': true}));
        await client!.request('turn/interrupt', {'threadId': id, 'turnId': (snapshot['thread']['turns'] as List).last['id']});
      }
      Future<Json> turn(String prompt) async {
        final result = await runTurn(client!, id, prompt: prompt);
        expect(result['status'], 'completed', reason: result.toString());
        return result;
      }
      Future<List<Json>> hostResults(String name) async {
        final page = jsonObject(await client!.request('thread/items/list', {'threadId': id, 'limit': 500}));
        return [for (final entry in page['data'] as List)
          if (entry['item']['type'] == 'dynamicToolCall' && entry['item']['tool'] == name)
            jsonObject(jsonDecode(entry['item']['contentItems'][0]['text'] as String))];
      }
      final commandStarted = lab == 'openai' ? client.events.stream.firstWhere((event) =>
        event['method'] == 'item/started' && event['params']['threadId'] == id &&
        event['params']['item']['type'] == 'commandExecution') : null;
      await turn('start');
      final a = File('${root.path}/a/session.pid'), b = File('${root.path}/b/session.pid');
      await _until(() => a.exists());
      expect(await _alive(a), isTrue, reason: 'A task-owned process must survive turn completion');
      if (lab == 'openai') {
        session = int.parse((await commandStarted!)['params']['item']['processId'] as String);
      }
      await turn('session');
      if (lab == 'openai') {
        expect((await hostResults('write_stdin')).last['output'], 'received:hello\n');
      }
      final second = await createThread(client, {'cwd': '${root.path}/b', 'provider': lab, 'config': {'thread_unload_delay_secs': 0}});
      expect((await runTurn(client, second, prompt: 'start'))['status'], 'completed');
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
        'task_id': second, 'name': 'mcp__local__probe', 'arguments': {'action': 'wait'},
      }, cancellation: siblingToken), throwsA(isA<CancelledException>()));
      await _until(() async => (await probe())['waiting'] == 1);
      for (final steer in [true, false]) {
        final done = terminal();
        await send('mcp');
        await _until(() async => (await probe())['waiting'] == 3);
        if (steer) {
          await send('continued', steer: true);
        } else {
          await interrupt();
        }
        expect((await done)['status'], steer ? 'completed' : 'interrupted');
        await _until(() async => (await probe())['waiting'] == 1);
        expect((await probe())['pid'], process, reason: 'Cancellation must preserve the shared MCP server and sibling call');
      }
      siblingToken.cancel(); await sibling;
      await _until(() async => (await probe())['waiting'] == 0);
      if (lab == 'openai') {
        for (final steer in [true, false]) {
          final started = client.events.stream.firstWhere((event) => event['params']?['threadId'] == id &&
            event['method'] == 'item/started' && event['params']['item']['type'] == 'sleep');
          final done = terminal();
          await send('sleep');
          await started.timeout(const Duration(seconds: 3));
          if (steer) {
            await send('continued', steer: true);
          } else {
            await interrupt();
          }
          expect((await done)['status'], steer ? 'completed' : 'interrupted');
          if (steer) {
            expect((modelRequests.last['input'] as List).where((item) => item['type'] == 'function_call_output')
              .any((item) => item['output'] is String && (item['output'] as String).endsWith('Sleep interrupted by new input.')), isTrue);
          }
        }
      }
      for (final steer in [true, false]) {
        final started = client.events.stream.firstWhere((event) => event['params']?['threadId'] == id &&
          event['method'] == 'item/started' && event['params']['item']['type'] == 'dynamicToolCall');
        final done = terminal();
        await send('spin');
        await Future.any([started, done.then((turn) => throw StateError('Spin ended before tool admission: $turn'))])
          .timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (steer) {
          await send('continued', steer: true);
        } else {
          await interrupt();
        }
        expect((await done)['status'], steer ? 'completed' : 'interrupted');
      }
      for (final steer in [true, false]) {
        final foreground = File('${root.path}/a/foreground.pid'), child = File('${root.path}/a/child.pid');
        if (await foreground.exists()) await foreground.delete();
        if (await child.exists()) await child.delete();
        final done = terminal();
        await send('short');
        await _until(() => child.exists());
        expect(await _alive(foreground), isTrue);
        if (steer) {
          await send('continued', steer: true);
        } else {
          await interrupt();
        }
        final event = await done;
        expect(event['status'], steer ? 'completed' : 'interrupted', reason: event.toString());
        await _until(() async => !await _alive(foreground) && !await _alive(child));
        expect(await _alive(a), isTrue);
        expect(await _alive(b), isTrue);
      }
      final waitingSession = File('${root.path}/a/wait-session.pid');
      if (lab == 'openai') {
        final done = terminal();
        await send('start-wait');
        await _until(() => _alive(waitingSession));
        await send('continued', steer: true);
        expect((await done)['status'], 'completed');
        expect(await _alive(waitingSession), isTrue, reason: 'Cancelling the initial exec wait must preserve its task-owned process');
      }
      Future<void> stopWith(String method) async {
        final child = File('${root.path}/a/child.pid');
        if (await child.exists()) await child.delete();
        final done = terminal();
        await send('short');
        await _until(() => _alive(child));
        if (method == 'turn/interrupt') { await interrupt(); }
        else { await client!.request(method, {'threadId': id}); }
        expect((await done)['status'], 'interrupted');
        expect(await _alive(child), isFalse);
      }
      await stopWith('turn/interrupt');
      await unloadThread(client, id);
      expect(await _alive(a), isFalse);
      if (lab == 'openai') expect(await _alive(waitingSession), isFalse);
      expect(await _alive(b), isTrue);
      await a.delete();
      await turn('start');
      await _until(() => a.exists());
      expect(await _alive(a), isTrue);
      await stopWith('thread/archive');
      expect(await _alive(a), isFalse);
      expect(await _alive(b), isTrue);
      await client.request('task.cancel', {'task_id': second});
      expect(await _alive(b), isTrue, reason: 'Stop does not unload a subscribed thread');
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
