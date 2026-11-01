import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  for (final providerId in ['openai', 'opencode']) {
    test('$providerId keeps filesystem skill context bounded across loading and task lifecycle', () async {
      final root = await Directory.systemTemp.createTemp('server-skills-');
      final data = await Directory('${root.path}/data').create();
      final home = await Directory('${root.path}/home').create();
      final work = await Directory('${root.path}/work').create();
      await Directory('${work.path}/.git').create();
      final chosen = File('${home.path}/.agents/skills/skill-399/SKILL.md');
      const body = 'PRIVATE_SKILL_BODY_START\nFollow these complete instructions.\nPRIVATE_SKILL_BODY_END\n';
      Future<void> skill(File file, String description, String content) async {
        await file.parent.create(recursive: true);
        await file.writeAsString('---\ndescription: $description\n---\n$content');
      }
      for (var i = 0; i < 400; i++) {
        await skill(File('${home.path}/.agents/skills/skill-${i.toString().padLeft(3, '0')}/SKILL.md'),
          'Use for global task $i. ' * 30, body);
      }
      final selectedId = await Link('${root.path}/selected-skill.md').create(chosen.path);
      final local = File('${work.path}/.agents/skills/local/SKILL.md');
      await skill(local, 'Use for the local task.', 'LOCAL_BODY');
      final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      AgentServer? server;
      AgentClient? client;
      addTearDown(() async {
        await client?.close();
        await server?.close();
        await provider.close(force: true);
        await root.delete(recursive: true);
      });
      final openCode = providerId == 'opencode';
      await File('${data.path}/config.yaml').writeAsString(jsonEncode({
        'default_provider': providerId,
        'providers': {providerId: {
          if (openCode) 'endpoint': 'http://127.0.0.1:${provider.port}/inference/openai/v1',
        }},
      }));
      await File('${data.path}/${openCode ? 'opencode-auth' : 'auth'}.json').writeAsString(jsonEncode({
        'version': 1, 'type': openCode ? 'opencode' : 'chatgpt',
        'server': 'https://opencode.ai/console',
        'access_token': 'fixture', 'refresh_token': 'fixture',
        'account_id': 'fixture', 'org_id': 'fixture',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }));
      final requests = <Json>[];
      var sequence = 0;
      provider.listen((request) async {
        final requestBody = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        requests.add(requestBody);
        final messages = (requestBody[openCode ? 'messages' : 'input'] as List).map(jsonObject).toList();
        final lastUser = messages.lastIndexWhere((message) => message['role'] == 'user');
        final load = lastUser >= 0 && messages[lastUser]['content'] == 'load omitted skill';
        final hasResult = messages.skip(lastUser + 1).any((message) =>
          message['role'] == 'tool' || message['type'] == 'custom_tool_call_output');
        request.response.headers.contentType = ContentType('text', 'event-stream');
        if (openCode) {
          final delta = load && !hasResult ? {
            'tool_calls': [{
              'index': 0, 'id': 'load-${++sequence}', 'type': 'function',
              'function': {'name': 'skill', 'arguments': jsonEncode({'id': selectedId.path})},
            }],
          } : {'content': 'Ready'};
          request.response.write('data: ${jsonEncode({
            'choices': [{'delta': delta, 'finish_reason': delta.containsKey('tool_calls') ? 'tool_calls' : 'stop'}],
          })}\n\ndata: [DONE]\n\n');
        } else {
          final output = messages.last['type'] == 'compaction_trigger' ? <Json>[
            {'type': 'compaction', 'encrypted_content': 'checkpoint-${++sequence}'},
          ] : load && !hasResult ? <Json>[
            {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec',
              'call_id': 'load-${++sequence}',
              'input': 'text(await tools.exec_command(${jsonEncode({
                'cmd': 'cat "${chosen.path}"', 'shell': '/bin/sh', 'login': false,
              })}));'},
          ] : <Json>[
            {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Ready'}]},
          ];
          request.response.write('data: ${jsonEncode({
            'type': 'response.completed',
            'response': {'status': 'completed', 'output': output,
              'usage': {'input_tokens': 100, 'output_tokens': 10}},
          })}\n\n');
        }
        await request.response.close();
      });

      Future<void> start() async {
        server = await AgentServer.startEmbedded(
          directory: data.path, configPath: '${data.path}/config.yaml', skillsHome: home.path,
          endpoint: openCode ? null : 'http://127.0.0.1:${provider.port}/responses',
        );
        client = await AgentClient.connect(server!.uri);
      }
      Future<Json> turn(String method, Json params) async {
        final terminal = client!.events.stream.firstWhere((event) =>
          ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']));
        await client!.request(method, params);
        final result = await terminal.timeout(const Duration(seconds: 20));
        expect(result['type'], 'turn.completed', reason: result.toString());
        return result;
      }
      List<String> catalogText() => (requests.last[openCode ? 'messages' : 'input'] as List)
        .map((item) => item['content'])
        .where((content) => content != null)
        .map((content) => content is String ? content
          : (content as List).map((part) => part['text'] ?? '').join())
        .where((text) => text.startsWith('<skills_instructions>')).toList();
      void bounded() {
        expect(catalogText().fold<int>(0, (total, text) => total + (utf8.encode(text).length + 3) ~/ 4),
          lessThanOrEqualTo(2000));
      }
      int bodyCount() => 'PRIVATE_SKILL_BODY_START'.allMatches(jsonEncode(requests.last)).length;
      Future<void> send(String id, [String prompt = 'continue']) async {
        await turn('task.send', {'task_id': id, 'prompt': prompt});
        bounded();
      }

      await start();
      final id = (await turn('task.start', {
        'cwd': work.path, 'prompt': 'continue', 'settings': {'context_limit': 100000},
      }))['task_id'] as String;
      bounded();
      final initial = catalogText();
      expect(initial, hasLength(1));
      expect(initial.single, contains('local'));
      expect(initial.single, isNot(contains('skill-399')));
      expect(bodyCount(), 0);
      expect(jsonEncode(requests.last), isNot(contains('LOCAL_BODY')));
      expect(jsonEncode(requests.last), isNot(contains('fingerprint')));

      final beforeLoad = requests.length;
      await send(id, 'load omitted skill');
      expect(requests.length, beforeLoad + 2);
      expect(catalogText(), initial);
      expect(bodyCount(), 1);
      expect(jsonEncode(requests.last), contains('PRIVATE_SKILL_BODY_END'));
      if (openCode) {
        final output = (requests.last['messages'] as List).lastWhere((message) => message['role'] == 'tool')['content'];
        expect(output, contains('<skill_content name="skill-399">'));
        expect(output, contains(body.trim()));
        expect(output, contains('Base directory for this skill: '));
        expect((requests.last['tools'] as List).where((tool) => tool['function']['name'] == 'skill'), hasLength(1));
      }
      await send(id);
      expect(catalogText(), initial);
      expect(bodyCount(), 1);

      await skill(local, 'Changed local guidance.', 'LOCAL_BODY');
      await send(id);
      final beforeRestart = catalogText();
      await client!.close();
      await server!.close();
      await start();
      await send(id);
      expect(catalogText(), beforeRestart);
      expect(bodyCount(), 1);

      // Fork/import rebuild metadata from history, including a compaction's
      // newer accounting. Neither may refund the already-emitted budget.
      for (final compacted in [false, true]) {
        if (compacted) {
          await turn('task.compact', {'task_id': id});
          await send(id);
          expect(catalogText(), hasLength(1));
          expect(catalogText().single, isNot(initial.single));
          expect(bodyCount(), 0, reason: 'Selected bodies are ordinary context, not automatically re-injected');
          await send(id, 'load omitted skill');
          expect(bodyCount(), 1);
        }
        final expected = catalogText();
        final fork = jsonObject(await client!.request('task.fork', {'task_id': id}))['task_id'] as String;
        await send(fork);
        expect(catalogText(), expected);
        expect(bodyCount(), 1);
        final bundle = '${root.path}/history-$compacted.jsonl';
        await client!.request('history.export', {'task_id': id, 'path': bundle});
        final imported = jsonObject(await client!.request('history.import', {'path': bundle}))['task_id'] as String;
        await send(imported);
        expect(catalogText(), expected);
        expect(bodyCount(), 1);
      }

    });
  }
}
