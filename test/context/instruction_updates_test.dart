import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  for (final lab in ['openai', 'opencode']) {
    test('$lab tracks mid-turn instruction edits, additions, and removals without rewriting history', () async {
      final root = await Directory.systemTemp.createTemp('live-instructions-');
      final data = await Directory('${root.path}/data').create();
      final work = await Directory('${root.path}/repo/sub').create(recursive: true);
      await Directory('${work.parent.path}/.git').create();
      final global = File('${data.path}/AGENTS.md');
      final project = File('${work.parent.path}/AGENTS.md');
      final nested = File('${work.path}/AGENTS.md');
      final rules = List.generate(30, (i) => 'Rule $i: preserve this instruction exactly.').join('\n');
      final original = 'Original rule.\n$rules\n';
      final changed = 'Updated rule.\n$rules\n';
      await global.writeAsString('Global original.\n');
      await project.writeAsString(original);
      final patch = '*** Begin Patch\n*** Update File: ${project.path}\n@@\n'
        '-Original rule.\n+Updated rule.\n'
        '*** Update File: ${global.path}\n@@\n-Global original.\n+Global updated.\n'
        '*** Add File: ${nested.path}\n+Nested addition.\n*** End Patch';
      final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final endpoint = 'http://127.0.0.1:${provider.port}';
      await File('${data.path}/config.yaml').writeAsString(jsonEncode({
        'default_provider': lab,
        'providers': {if (lab == 'opencode') lab: {
          'endpoint': '$endpoint/inference/openai/v1', 'settings': {'reasoning': 'low'},
        }},
      }));
      await File('${data.path}/${lab == 'openai' ? 'auth' : 'opencode-auth'}.json').writeAsString(jsonEncode({
        'type': lab == 'openai' ? 'chatgpt' : 'opencode',
        'access_token': 'fixture', 'refresh_token': 'fixture',
        if (lab == 'openai') 'account_id': 'fixture',
        if (lab == 'opencode') ...{'version': 1, 'server': 'https://opencode.ai/console', 'org_id': 'fixture'},
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }));
      final requests = <Json>[];
      var step = 0;
      provider.listen((http) async {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(http).join()));
        requests.add(body);
        http.response.headers.contentType = ContentType('text', 'event-stream');
        if (lab == 'openai') {
          final compact = (body['input'] as List).last['type'] == 'compaction_trigger';
          final output = compact ? <Json>[
            {'type': 'compaction', 'encrypted_content': 'instruction-checkpoint'},
          ] : step < 2 ? <Json>[
            {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'step_$step',
              'input': step++ == 0 ? 'text(await tools.apply_patch(${jsonEncode(patch)}));'
                : 'text("Another unchanged boundary.");'},
          ] : <Json>[
            {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Done'}]},
          ];
          http.response.write('data: ${jsonEncode({
            'type': 'response.completed', 'response': {'status': 'completed', 'output': output,
              'usage': {'input_tokens': 100, 'output_tokens': 10}},
          })}\n\n');
        } else {
          final delta = step < 2 ? <String, dynamic>{
            'tool_calls': [{
              'index': 0, 'id': 'step_$step', 'type': 'function', 'function': {
                'name': step == 0 ? 'patch' : 'read',
                'arguments': jsonEncode(step++ == 0 ? {'patchText': patch} : {'path': project.path}),
              },
            }],
          } : <String, dynamic>{'content': 'Done'};
          http.response.write('data: ${jsonEncode({
            'choices': [{'delta': delta, 'finish_reason': delta.containsKey('tool_calls') ? 'tool_calls' : 'stop'}],
          })}\n\ndata: [DONE]\n\n');
        }
        await http.response.close();
      });
      final server = await AgentServer.startEmbedded(
        directory: data.path, configPath: '${data.path}/config.yaml',
        endpoint: '$endpoint/responses', skillsHome: root.path,
      );
      final client = await AgentClient.connect(server.uri);
      addTearDown(() async {
        await client.close();
        await server.close();
        await provider.close(force: true);
        await root.delete(recursive: true);
      });
      Future<Json> turn(String method, Json params) async {
        final terminal = client.events.stream.firstWhere((event) =>
          ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']));
        await client.request(method, params);
        final result = await terminal.timeout(const Duration(seconds: 15));
        expect(result['type'], 'turn.completed', reason: result.toString());
        return result;
      }
      List<Json> input(Json request) => (request[lab == 'openai' ? 'input' : 'messages'] as List).map(jsonObject).toList();
      List<String> instructions(Json request) => [for (final item in input(request))
        if (item['content'] case final String text when text.startsWith('# AGENTS.md instructions') ||
            text.contains('Instructions from: ') || text.startsWith('The instructions from ') ||
            text == 'Previously loaded instructions no longer apply.') text];

      final started = await turn('task.start', {'cwd': work.path, 'prompt': 'Update the instructions.'});
      final id = started['task_id'];
      Future<List<Json>> updates() async => (await client.request('history.page', {'task_id': id, 'limit': 500}) as List)
          .map(jsonObject).where((event) => event['type'] == 'agents.updated').toList();
      expect(requests, hasLength(3));
      expect(input(requests[1]).take(input(requests[0]).length).toList(), input(requests[0]));
      expect(input(requests[2]).take(input(requests[1]).length).toList(), input(requests[1]));
      expect(instructions(requests[0]), hasLength(1));
      expect(instructions(requests[1]), hasLength(2));
      expect(instructions(requests[2]), instructions(requests[1]), reason: 'An unchanged boundary must not repeat the update');
      final text = instructions(requests[1]).last;
      expect(text, contains('Global updated.'));
      expect(text, contains('Nested addition.'));
      if (lab == 'opencode') {
        expect(text, contains("The instructions from ${project.path} changed. Here's the diff:"));
        expect(text, contains('-Original rule.\n+Updated rule.'));
        expect(text, contains('New instructions apply from:\nInstructions from: ${nested.path}'));
        expect(text, isNot(contains('Rule 29:')));
      } else {
        expect(text, contains('These AGENTS.md instructions replace all previously provided AGENTS.md instructions.'));
        expect(text, contains(changed));
      }
      expect(await global.readAsString(), 'Global updated.\n');
      expect(await project.readAsString(), changed);
      final changes = await updates();
      expect(changes, hasLength(2));
      expect((changes.last['data']['snapshot']['files'] as List).map((file) => file['text']),
        ['Global updated.\n', changed, 'Nested addition.\n']);

      // Move the tool exchanges out of the summarizer's retained recent tail.
      for (var i = 0; i < 2; i++) {
        await turn('task.send', {'task_id': id, 'prompt': 'Continue $i.'});
      }
      await turn('task.compact', {'task_id': id});
      final history = await client.request('history.page', {'task_id': id, 'limit': 500}) as List;
      final restored = (history.lastWhere((event) => event['type'] == 'context.compacted')['data']['input'] as List)
          .where((item) => item['native']?['harness']?['context'] == 'agents_md').toList();
      expect(restored, hasLength(1));
      expect(jsonEncode(restored.single), contains('Updated rule.'));
      expect(jsonEncode(restored.single), contains('Global updated.'));
      expect(jsonEncode(restored.single), isNot(contains('Original rule.')));
      expect(jsonEncode(restored.single), isNot(contains('replace all previously')));
      expect(jsonEncode(restored.single), isNot(contains('```diff')));

      await turn('task.send', {'task_id': id, 'prompt': 'Continue after compaction.'});
      expect(instructions(requests.last), hasLength(1));
      final prefix = input(requests.last);
      await File('${project.path}.save').writeAsString(changed);
      await File('${project.path}.save').rename(project.path);
      await turn('task.send', {'task_id': id, 'prompt': 'Same contents, new file.'});
      expect(input(requests.last).take(prefix.length).toList(), prefix);
      expect(input(requests.last).length, prefix.length + 2);
      expect(await updates(), hasLength(2));

      await global.delete();
      await nested.delete();
      await turn('task.send', {'task_id': id, 'prompt': 'Only repository rules remain.'});
      final removal = instructions(requests.last).last;
      if (lab == 'opencode') {
        expect(removal, 'The instructions from ${global.path} no longer apply.\n\n'
          'The instructions from ${nested.path} no longer apply.');
      } else {
        expect(removal, contains('replace all previously provided AGENTS.md instructions.'));
        expect(removal, contains(changed));
        expect(removal, isNot(contains('Global updated.')));
        expect(removal, isNot(contains('Nested addition.')));
      }
      expect(await updates(), hasLength(3));

      await project.delete();
      await turn('task.send', {'task_id': id, 'prompt': 'No rules remain.'});
      final empty = instructions(requests.last);
      expect(empty.last, contains(lab == 'opencode' ? 'Previously loaded instructions no longer apply.'
        : 'The previously provided AGENTS.md instructions no longer apply.'));
      await turn('task.send', {'task_id': id, 'prompt': 'Still empty.'});
      expect(instructions(requests.last), empty);
      expect(await updates(), hasLength(4));

      await project.writeAsString('Restored instructions.');
      await turn('task.send', {'task_id': id, 'prompt': 'Rules apply again.'});
      expect(instructions(requests.last).last, contains('Restored instructions.'));
      expect(instructions(requests.last).last, isNot(contains('replace all previously')));
      expect(await updates(), hasLength(5));
    });
  }
}
