import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import '../support/openai_output.dart';

void main() {
  test('code-mode-only discovery stays nested across catalog edits and compaction', () async {
    final root = await Directory.systemTemp.createTemp('deferred-context-');
    final config = File('${root.path}/config.yaml');
    const guidance = 'This server inspects process ownership and returns a process identifier. '
      'Use the returned identifier to distinguish supervised process generations. '
      'The tool results identify the process that actually handled the request. '
      'Preserve the identifier while inspecting the current supervised process. Original guidance tail.';
    String configuration(String description, {String? instructions = guidance}) => jsonEncode({
      'mcp_servers': {'archive': {
        'command': Platform.resolvedExecutable,
        'args': [File('test/fixtures/mcp_stdio.dart').absolute.path],
        'env': {'MCP_EXTRA_TOOLS': '120', 'MCP_TOOL_DESCRIPTION': description,
          'MCP_INSTRUCTIONS': ?instructions},
        'legacy_fallback': false,
      }},
    });
    Future<void> configure(String description, {String? instructions = guidance}) =>
      config.writeAsString(configuration(description, instructions: instructions), flush: true);
    await configure('Inspect the supervised process');
    await File('${root.path}/note.txt').writeAsString('before\n');
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture',
      'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    final requests = <Json>[];
    var sequence = 0;
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((http) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(http).join()));
      requests.add(body);
      final input = (body['input'] as List).map(jsonObject).toList();
      final lastUser = input.lastIndexWhere((item) => item['role'] == 'user');
      final prompt = input[lastUser]['content'];
      final results = input.skip(lastUser + 1).where((item) =>
        ['custom_tool_call_output', 'function_call_output'].contains(item['type']),
      ).toList();
      final output = <Json>[];
      if (input.last['type'] == 'compaction_trigger') {
        output.add({'type': 'compaction', 'encrypted_content': 'discovery-checkpoint'});
      } else if (prompt == 'code' && results.isEmpty) {
        final patch = '*** Begin Patch\n*** Update File: ${config.path}\n@@\n'
          '-${configuration('Inspect the supervised process')}\n'
          '+${configuration('Discovered after an in-cell config edit', instructions: guidance.replaceFirst('Original guidance tail.', 'Current guidance tail.'))}\n*** End Patch';
        output.add({
          'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec',
          'call_id': 'call_${++sequence}',
          'input': '''
            await tools.apply_patch(${jsonEncode(patch)});
            text(await tools.tool_search({query:"mcp__archive__probe",limit:1}));
            text(ALL_TOOLS.find(t => t.name === "mcp__archive__probe"));
            text(await tools.mcp__archive__probe({action:"inspect"}));
            text(await tools.tool_search({query:"filesystem read_file write_file exec_command terminal",limit:3}));
            const before = await tools.exec_command({cmd:"cat note.txt", shell:"/bin/sh", login:false});
            await tools.apply_patch("*** Begin Patch\\n*** Update File: note.txt\\n@@\\n-before\\n+after\\n*** End Patch");
            const after = await tools.exec_command({cmd:"cat note.txt", shell:"/bin/sh", login:false});
            text({before:before.output, after:after.output});
          ''',
        });
      } else if (prompt == 'nested' && results.isEmpty) {
        output.add({
          'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec',
          'call_id': 'call_${++sequence}',
          'input': 'text(await tools.tool_search({query:"mcp__archive__probe",limit:1})); '
            'text(await tools.mcp__archive__probe({action:"inspect"}));',
        });
      } else {
        output.add({'type': 'message', 'role': 'assistant', 'content': [
          {'type': 'output_text', 'text': 'Done'},
        ]});
      }
      http.response.headers.contentType = ContentType('text', 'event-stream');
      http.response.write('data: ${jsonEncode({
        'type': 'response.completed', 'response': {'status': 'completed', 'output': output,
          'usage': {'input_tokens': 100, 'output_tokens': 10}},
      })}\n\n');
      await http.response.close();
    });
    final endpoint = 'http://127.0.0.1:${provider.port}/responses';
    var server = await AgentServer.startEmbedded(directory: root.path, configPath: config.path, endpoint: endpoint, skillsHome: root.path);
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
      final result = await terminal.timeout(const Duration(seconds: 20));
      expect(result['type'], 'turn.completed', reason: result.toString());
      return result;
    }
    List<Json> definitions(Json request) => [
      for (final namespace in request['tools'] as List)
        if (!{'exec', 'wait', 'web'}.contains(namespace['name']))
          ...((namespace['tools'] as List?) ?? [namespace]).map(jsonObject),
    ];

    final started = await turn('task.start', {
      'cwd': root.path, 'prompt': 'seed',
      'client_tools': [for (var i = 0; i < 120; i++) {
        'name': 'client_unused_$i', 'description': 'Another unrelated operation',
        'inputSchema': {'type': 'object', 'properties': {'client_schema_$i': {'type': 'boolean'}}},
      }],
    });
    final id = started['task_id'];
    final prefix = requests.single['input'] as List;
    expect(requests.single.containsKey('instructions'), false);
    final initialTools = requests.single['tools'] as List;
    expect(initialTools.where((tool) => tool['type'] == 'tool_search'), isEmpty);
    final exec = initialTools.singleWhere((tool) => tool['name'] == 'exec');
    final description = exec['description'] as String;
    for (final name in ['exec_command', 'write_stdin']) {
      expect(description, contains('declare const tools: { $name('));
    }
    expect(description, contains('apply_patch(input: string)'));
    expect(description, contains('ALL_TOOLS'));
    expect(definitions(requests.single), isEmpty);
    expect(jsonEncode(prefix), isNot(contains('unused_schema_')));
    expect(jsonEncode(prefix), isNot(contains('client_schema_')));
    expect(jsonEncode(prefix), isNot(contains('Original guidance tail.')));
    expect(utf8.encode(jsonEncode(prefix.skip(1).toList())).length, lessThan(5000));

    await turn('task.send', {'task_id': id, 'prompt': 'code'});
    expect(definitions(requests.last), isEmpty, reason: 'Code-mode discovery must not load native schemas');
    expect((requests.last['input'] as List).take(prefix.length), prefix);
    final codeResult = (requests.last['input'] as List).lastWhere((item) => item['type'] == 'custom_tool_call_output');
    final printed = printedOpenAIOutput(codeResult['output']);
    final found = jsonDecode(printed.first)['tools'] as List;
    expect(found.single['name'], 'mcp__archive__probe');
    expect(found.single['description'], contains('Discovered after an in-cell config edit'));
    expect(found.single['description'], contains('declare const tools: { mcp__archive__probe('));
    expect(found.single['description'], contains('action'));
    expect(found.single['description'], contains('Current guidance tail.'));
    expect(found.single.keys, unorderedEquals(['name', 'description']));
    expect(openAIMessageText((requests.last['input'] as List).lastWhere((item) => item['role'] == 'developer') as Map),
      contains('Deferred tool namespaces:'));
    expect(jsonDecode(printed[1])['description'], contains('declare const tools: { mcp__archive__probe('));
    expect(jsonDecode(jsonDecode(printed[2])['content'][0]['text'])['pid'], isPositive);
    expect(jsonDecode(printed[3]), {'tools': []},
      reason: 'Codex search indexes deferred tools; built-ins are advertised in functions.exec');
    expect(jsonDecode(printed.last), {'before': 'before\n', 'after': 'after\n'});
    expect(await File('${root.path}/note.txt').readAsString(), 'after\n');

    for (var i = 0; i < 2; i++) {
      await turn('task.compact', {'task_id': id});
      await turn('task.send', {'task_id': id, 'prompt': 'nested'});
      expect(definitions(requests.last), isEmpty);
      final result = (requests.last['input'] as List).lastWhere((item) => item['type'] == 'custom_tool_call_output');
      final output = printedOpenAIOutput(result['output']);
      expect(jsonDecode(output.first)['tools'].single['name'], 'mcp__archive__probe');
      expect(jsonDecode(jsonDecode(output.last)['content'][0]['text'])['pid'], isPositive);
    }
    expect(requests.every((request) => !request.containsKey('instructions')), isTrue);
    expect(requests.every((request) => jsonEncode(request['tools']) == jsonEncode(initialTools)), isTrue);

  });
}
