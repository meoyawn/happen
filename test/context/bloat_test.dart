import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import '../support/thread_names.dart';
import '../support/openai_output.dart';
import '../support/thread.dart';

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
      if (await respondToThreadName(request, body)) return;
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
      ] : ['catalog baseline', 'one changed tool'].contains(openAIMessageText(input[lastUser])) ? <Json>[
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
    Future<Json> turn(String id, {String prompt = '', bool compact = false, Json settings = const {}}) async {
      final result = await runTurn(client, id, prompt: prompt, compact: compact, settings: settings);
      expect(result['status'], 'completed', reason: result.toString());
      return result;
    }

    final id = await createThread(client, {'cwd': work.path});
    List<Object?>? previousInput;
    for (var i = 0; i < 5; i++) {
      final before = requests.length;
      await turn(id, prompt: 'turn-$i', settings: {
        'effort': i == 0 ? 'low' : 'high',
        if (i == 2) 'developerInstructions': 'Keep responses short.',
      });
      expect(requests.length, before + 2);
      final initial = requests[before];
      final completed = requests[before + 1];
      final input = initial['input'] as List;
      if (previousInput == null) {
        expect(input, hasLength(5));
        expect(input[0], containsPair('type', 'additional_tools'));
        expect(input[1], containsPair('role', 'developer'));
        expect(openAIMessageText(input[1] as Map), GptModel('gpt-6.1-sol').instructions);
        expect(openAIMessageText(input[2] as Map), startsWith('<environment_context>\n  <cwd>${work.path}</cwd>\n'));
        expect(openAIMessageText(input[2] as Map), contains(RegExp(r'<shell>(zsh|bash|sh|pwsh|powershell|cmd)</shell>')));
        expect(openAIMessageText(input[2] as Map), contains(RegExp(r'<current_date>\d{4}-\d{2}-\d{2}</current_date>')));
        expect(openAIMessageText(input[2] as Map), contains(RegExp(r'<timezone>[^<]+</timezone>')));
        expect(openAIMessageText(input[2] as Map), endsWith('</environment_context>'));
        expect(input[3], containsPair('role', 'user'));
        expect(openAIMessageText(input[3] as Map), 'turn-0');
        expect(input.last, {'type': 'configuration_update', 'reasoning': {'effort': 'low'}});
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
      expect(outputs, everyElement(containsPair('output', contains(containsPair('text', 'visible-tool-result')))));
      expect(jsonEncode(completed['input']), isNot(contains(privateReceipt)));
      expect(initial.containsKey('tools'), false);
      expect(initial.containsKey('instructions'), false);
      expect(input.take(2).toList(), (requests.first['input'] as List).take(2).toList());
      expect(input.where((item) => item['type'] == 'additional_tools'), hasLength(1));
      expect(input.where((item) => openAIMessageText(item as Map) == GptModel('gpt-6.1-sol').instructions), hasLength(1));
      expect(initial['reasoning']['effort'], 'low');
      expect((completed['input'] as List).where((item) => item['type'] == 'configuration_update'),
        hasLength(i == 0 ? 1 : 2));
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
    await turn(id, prompt: 'catalog baseline');
    previousInput = requests.last['input'] as List;
    await client.request('tools.register', {'task_id': id, 'tools': [stable, {
      ...browser,
      'inputSchema': {'properties': {'tab': {'type': 'integer'}}, 'type': 'object'},
    }]});
    final beforeReorder = requests.length;
    await turn(id, prompt: 'same catalog, different order');
    final reordered = requests[beforeReorder]['input'] as List;
    expect(reordered.take(previousInput.length).toList(), previousInput);
    expect(reordered.length, previousInput.length + 2,
      reason: 'Catalog and JSON object ordering must not redeclare unchanged tools');

    previousInput = requests.last['input'] as List;
    await client.request('tools.register', {'task_id': id, 'tools': [stable, {
      ...browser, 'description': 'Changed title guidance',
    }]});
    final beforeChange = requests.length;
    await turn(id, prompt: 'one changed tool');
    final changed = (requests[beforeChange]['input'] as List).skip(previousInput.length).toList();
    expect(changed.where((item) => item['type'] == 'additional_tools'), isEmpty);
    expect(jsonEncode(changed), isNot(contains('browser_title')));
    expect(jsonEncode(changed), isNot(contains('stable_lookup')));
    expect(jsonEncode(changed), isNot(contains('Unchanged catalog guidance')));
    final discovery = (requests.last['input'] as List).lastWhere((item) => item['type'] == 'custom_tool_call_output');
    expect(printedOpenAIOutput(discovery['output']).join('\n'), contains('Changed title guidance'));

    await client.request('tools.register', {'task_id': id, 'tools': <Object?>[]});
    final beforeRemoval = requests.length;
    await turn(id, prompt: 'removed tools');
    final notice = (requests[beforeRemoval]['input'] as List).lastWhere((item) => item['role'] == 'developer');
    expect(openAIMessageText(notice as Map), '<tools>\nRemoved deferred tool namespaces:\n'
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
    await turn(id, prompt: 'after restart');
    final resumed = requests[beforeResume]['input'] as List;
    expect(resumed.take(previousInput.length).toList(), previousInput);
    expect(resumed.length, previousInput.length + 4);
    expect(resumed.last, {'type': 'configuration_update', 'reasoning': {'effort': 'high'}});
    expect(jsonEncode(resumed.skip(previousInput.length).toList()), contains('The tool runtime was restarted.'));

    for (var i = 0; i < 2; i++) {
      await turn(id, compact: true);
      final context = await contextItems(client, id);
      expect(context.where((item) => item['native']?['harness']?['context'] == 'environment'), hasLength(1));
      expect(context.where((item) => ['agents_md', 'mcp', 'client_tools'].contains(item['native']?['harness']?['context'])), isEmpty);
      expect(context.where((item) => item['role'] == 'developer'), hasLength(2));
      expect(context.where((item) => item['kind'] == 'tools'), hasLength(1));
      expect(context.where((item) => item['native']?['harness']?['context'] == 'model'), hasLength(1));
      expect(context.first['kind'], 'tools');
      expect(context[1]['native']?['harness']?['context'], 'model');
      expect(jsonEncode(context), contains('Keep responses short.'));
      expect(context.where((item) => item['kind'] == 'compaction'), hasLength(1));
      expect(context.where((item) => item['kind'] == 'configuration'), hasLength(1));
      expect(context.where((item) => item['role'] == 'tool'), isEmpty);
      expect(jsonEncode(context), isNot(contains(privateReceipt)));
      expect(jsonObject(threadMetadata(root.path, id, 'values'))['unprinted'], privateReceipt);
      await turn(id, prompt: 'after compact-$i');
      expect((requests.last['input'] as List).first['tools'], (requests.first['input'] as List).first['tools']);
      expect(requests.last.containsKey('tools'), false);
      expect(jsonEncode(requests.last['input']), isNot(contains(privateReceipt)));
    }
  });
}
