import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('multi-turn model context adds only new work and compaction restores one current baseline', () async {
    final root = await Directory.systemTemp.createTemp('server-context-');
    final work = await Directory('${root.path}/work').create();
    final receipt = File('${work.path}/receipt.txt');
    final privateReceipt = 'unprinted-${newId()}';
    await receipt.writeAsString(privateReceipt);
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt',
      'access_token': 'fixture',
      'refresh_token': 'fixture',
      'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    final requests = <Json>[];
    var sequence = 0;
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requests.add(body);
      final input = (body['input'] as List).map(jsonObject).toList();
      final lastUser = input.lastIndexWhere((item) => item['role'] == 'user');
      final hasResult = input.skip(lastUser + 1).any((item) =>
        item['type'] == 'custom_tool_call_output',
      );
      final output = input.last['type'] == 'compaction_trigger' ? <Json>[
        {'type': 'compaction', 'encrypted_content': 'checkpoint-${++sequence}'},
      ] : hasResult ? <Json>[
        {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Done'}]},
      ] : ['catalog baseline', 'one changed tool'].contains(input[lastUser]['content']) ? <Json>[
        {
          'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec',
          'call_id': 'context_${++sequence}',
          'input': 'text(await tools.tool_search({query:"client",limit:2}));',
        },
      ] : <Json>[
        {
          'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec',
          'call_id': 'context_${++sequence}',
          'input': '''
            const result = await tools.exec_command({cmd: ${jsonEncode('cat "${receipt.path}"')}});
            store("unprinted", result.output);
            text("visible-tool-result");
          ''',
        },
      ];
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({
        'type': 'response.completed',
        'response': {'status': 'completed', 'output': output,
          'usage': {'input_tokens': 100, 'output_tokens': 10}},
      })}\n\n');
      await request.response.close();
    });
    final endpoint = 'http://127.0.0.1:${provider.port}/responses';
    var server = await AgentServer.startEmbedded(
      directory: root.path, configPath: '${root.path}/config.yaml', endpoint: endpoint,
      skillsHome: root.path,
    );
    var client = await AgentClient.connect(server.uri);
    addTearDown(() async {
      await client.close();
      await server.close();
      await provider.close(force: true);
      await root.delete(recursive: true);
    });
    Future<Json> turn(String method, Json params) async {
      final terminal = client.events.stream.firstWhere((event) =>
        ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']),
      );
      await client.request(method, params);
      final result = await terminal.timeout(const Duration(seconds: 15));
      expect(result['type'], 'turn.completed', reason: result.toString());
      return result;
    }

    String? id;
    List? previousInput;
    for (var i = 0; i < 5; i++) {
      final before = requests.length;
      final result = await turn(id == null ? 'task.start' : 'task.send', {
        if (id == null) 'cwd': work.path else 'task_id': id,
        'prompt': 'turn-$i',
        'reasoning': i == 0 ? 'low' : 'high',
        if (i == 2) 'instructions': 'Keep responses short.',
      });
      id = result['task_id'] as String;
      expect(requests.length, before + 2);
      final initial = requests[before];
      final completed = requests[before + 1];
      final input = initial['input'] as List;
      if (previousInput == null) {
        // Codex Responses Lite: one declarations/base prefix, then context and input.
        expect(input, hasLength(4));
        expect(input[0]['type'], 'additional_tools');
        expect(input[1], {'role': 'developer', 'content': GptModel('gpt-6.1-sol').instructions});
        expect(input[2]['content'], '<environment_context>\n  <cwd>${work.path}</cwd>\n'
          '  <shell>${Platform.environment['SHELL']!.split('/').last}</shell>\n</environment_context>');
        expect(input.last, {'role': 'user', 'content': 'turn-0'});
      } else {
        expect(input.take(previousInput.length).toList(), previousInput);
        expect(input.length, previousInput.length + 2 + (i == 1 || i == 2 ? 1 : 0));
      }
      expect((completed['input'] as List).take(input.length).toList(), input);
      expect((completed['input'] as List).length, input.length + 2);
      final calls = (completed['input'] as List).where((item) => item['type'] == 'custom_tool_call').toList();
      final outputs = (completed['input'] as List).where((item) => item['type'] == 'custom_tool_call_output').toList();
      expect(calls, hasLength(i + 1));
      expect(outputs.map((item) => item['call_id']).toList(), calls.map((item) => item['call_id']).toList());
      expect(outputs.map((item) => item['output']).toSet(), {jsonEncode({'output': ['visible-tool-result']})});
      expect(jsonEncode(completed['input']), isNot(contains(privateReceipt)));
      expect(initial['tools'], isEmpty);
      expect(initial['instructions'], '');
      expect(input.take(2).toList(), (requests.first['input'] as List).take(2).toList());
      expect(input.where((item) => item['type'] == 'additional_tools'), hasLength(1));
      expect(input.where((item) => item['content'] == GptModel('gpt-6.1-sol').instructions), hasLength(1));
      expect(initial['reasoning']['effort'], 'low');
      expect((completed['input'] as List).where((item) => item['type'] == 'configuration_update'),
        hasLength(i == 0 ? 0 : 1));
      previousInput = completed['input'] as List;
    }

    final browser = <String, dynamic>{
      'name': 'browser_title', 'description': 'Read the title',
      'inputSchema': {'type': 'object', 'properties': {'tab': {'type': 'integer'}}},
    };
    final stable = <String, dynamic>{
      'name': 'stable_lookup', 'description': 'Unchanged catalog guidance',
      'inputSchema': {'type': 'object'},
    };
    await client.request('tools.register', {'task_id': id, 'tools': [browser, stable]});
    await turn('task.send', {'task_id': id, 'prompt': 'catalog baseline'});
    previousInput = requests.last['input'] as List;
    await client.request('tools.register', {'task_id': id, 'tools': [stable, {
      ...browser,
      'inputSchema': {'properties': {'tab': {'type': 'integer'}}, 'type': 'object'},
    }]});
    final beforeReorder = requests.length;
    await turn('task.send', {'task_id': id, 'prompt': 'same catalog, different order'});
    final reordered = requests[beforeReorder]['input'] as List;
    expect(reordered.take(previousInput.length).toList(), previousInput);
    expect(reordered.length, previousInput.length + 2,
      reason: 'Catalog and JSON object ordering must not redeclare unchanged tools');

    previousInput = requests.last['input'] as List;
    await client.request('tools.register', {'task_id': id, 'tools': [stable, {
      ...browser, 'description': 'Changed title guidance',
    }]});
    final beforeChange = requests.length;
    await turn('task.send', {'task_id': id, 'prompt': 'one changed tool'});
    final changed = (requests[beforeChange]['input'] as List).skip(previousInput.length).toList();
    expect(changed.where((item) => item['type'] == 'additional_tools'), isEmpty);
    expect(jsonEncode(changed), isNot(contains('browser_title')));
    expect(jsonEncode(changed), isNot(contains('stable_lookup')));
    expect(jsonEncode(changed), isNot(contains('Unchanged catalog guidance')));
    final discovery = (requests.last['input'] as List).lastWhere((item) => item['type'] == 'custom_tool_call_output');
    expect(discovery['output'], contains('Changed title guidance'));

    await client.request('tools.register', {'task_id': id, 'tools': []});
    final beforeRemoval = requests.length;
    await turn('task.send', {'task_id': id, 'prompt': 'removed tools'});
    final notice = (requests[beforeRemoval]['input'] as List).lastWhere((item) => item['role'] == 'developer');
    expect(notice['content'], '<tools>\nRemoved deferred tool namespaces:\n'
      '- client: Tools in the client namespace.\nNo deferred tool namespaces remain.\n</tools>');
    previousInput = requests.last['input'] as List;

    await client.close();
    await server.close();
    server = await AgentServer.startEmbedded(
      directory: root.path, configPath: '${root.path}/config.yaml', endpoint: endpoint,
      skillsHome: root.path,
    );
    client = await AgentClient.connect(server.uri);
    final beforeResume = requests.length;
    await turn('task.send', {'task_id': id, 'prompt': 'after restart'});
    final resumed = requests[beforeResume]['input'] as List;
    expect(resumed.take(previousInput.length).toList(), previousInput);
    expect(resumed.length, previousInput.length + 2);

    for (var i = 0; i < 2; i++) {
      await turn('task.compact', {'task_id': id});
      final history = await client.request('history.page', {'task_id': id, 'limit': 500}) as List;
      final checkpoint = history.lastWhere((event) => event['type'] == 'context.compacted');
      final context = checkpoint['data']['input'] as List;
      expect(context.where((item) => item['native']?['harness']?['context'] == 'environment'), hasLength(1));
      expect(context.where((item) => ['agents_md', 'mcp', 'client_tools'].contains(item['native']?['harness']?['context'])), isEmpty);
      expect(context.where((item) => item['role'] == 'developer'), hasLength(2));
      expect(context[0]['native']['harness']['context'], 'top_level_tools');
      expect(context[1]['native']['harness']['context'], 'model');
      expect(context.where((item) => item['kind'] == 'tools'), hasLength(1));
      expect(context.where((item) => item['native']?['harness']?['context'] == 'model'), hasLength(1));
      expect(jsonEncode(context), contains('Keep responses short.'));
      expect(context.where((item) => item['kind'] == 'compaction'), hasLength(1));
      expect(context.where((item) => item['kind'] == 'configuration'), hasLength(1));
      expect(context.where((item) => item['role'] == 'tool'), isEmpty);
      expect(jsonEncode(context), isNot(contains(privateReceipt)));
      final stored = history.lastWhere((event) => event['type'] == 'tool.completed');
      expect(stored['data']['values']['unprinted'], privateReceipt);
      await turn('task.send', {'task_id': id, 'prompt': 'after compact-$i'});
      expect((requests.last['input'] as List).take(2).toList(), (requests.first['input'] as List).take(2).toList());
      expect(jsonEncode(requests.last['input']), isNot(contains(privateReceipt)));
    }
  });
}
