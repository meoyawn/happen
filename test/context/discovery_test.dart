import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('discovery bounds context and restores only selected native tools', () async {
    final root = await Directory.systemTemp.createTemp('deferred-context-');
    final config = File('${root.path}/config.yaml');
    const guidance = 'This server inspects process ownership and returns a process identifier. '
      'Use the returned identifier to distinguish supervised process generations. '
      'The tool results identify the process that actually handled the request. Original guidance tail.';
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
        ['tool_search_output', 'custom_tool_call_output', 'function_call_output'].contains(item['type']),
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
          ''',
        });
      } else if ((prompt == 'native' || prompt == 'again') && results.isEmpty) {
        output.add({
          'type': 'tool_search_call', 'execution': 'client', 'status': 'completed',
          'id': 'ts_${++sequence}', 'call_id': 'call_$sequence',
          'arguments': {'query': 'mcp__archive__probe', 'limit': 1},
        });
      } else if (prompt == 'native' && results.length == 1 || prompt == 'direct' && results.isEmpty) {
        output.add({
          'type': 'function_call', 'namespace': 'mcp__archive', 'name': 'probe',
          'call_id': 'call_${++sequence}', 'arguments': '{"action":"inspect"}',
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
    var server = await AgentServer.startEmbedded(directory: root.path, configPath: config.path, endpoint: endpoint);
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
      for (final item in (request['input'] as List).map(jsonObject))
        if (['additional_tools', 'tool_search_output'].contains(item['type']))
          for (final namespace in item['tools'] as List)
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
    final initialTools = requests.single['tools'];
    expect(definitions(requests.single), isEmpty);
    expect(jsonEncode(prefix), isNot(contains('unused_schema_')));
    expect(jsonEncode(prefix), isNot(contains('client_schema_')));
    expect(jsonEncode(prefix), isNot(contains('Original guidance tail.')));
    expect(utf8.encode(jsonEncode(prefix)).length, lessThan(5000));

    await turn('task.send', {'task_id': id, 'prompt': 'code'});
    expect(definitions(requests.last), isEmpty, reason: 'Code-mode discovery must not load native schemas');
    expect((requests.last['input'] as List).take(prefix.length), prefix);
    final codeResult = (requests.last['input'] as List).lastWhere((item) => item['type'] == 'custom_tool_call_output');
    final printed = jsonDecode(codeResult['output'] as String)['output'] as List;
    final found = jsonDecode(printed.first as String)['tools'] as List;
    expect(found.single['name'], 'mcp__archive__probe');
    expect(found.single['description'], contains('Discovered after an in-cell config edit'));
    expect(found.single['description'], contains('tools.mcp__archive__probe'));
    expect(found.single['description'], contains('action'));
    expect(jsonDecode(printed.first as String)['instructions'].single['text'], contains('Current guidance tail.'));
    expect((requests.last['input'] as List).lastWhere((item) => item['role'] == 'developer')['content'],
      contains('Previously retrieved usage guidance'));
    expect(jsonDecode(printed[1] as String)['description'], contains('tools.mcp__archive__probe'));
    expect(jsonDecode(jsonDecode(printed.last as String)['content'][0]['text'])['pid'], isPositive);

    await turn('task.send', {'task_id': id, 'prompt': 'native'});
    expect(definitions(requests.last).map((tool) => tool['name']), ['probe']);
    final nativeResult = (requests.last['input'] as List).singleWhere((item) => item['type'] == 'tool_search_output');
    expect(nativeResult['execution'], 'client');
    expect(nativeResult['status'], 'completed');
    expect(nativeResult['tools'][0]['name'], 'mcp__archive');
    expect(nativeResult['tools'][0]['tools'][0]['parameters']['properties']['action']['type'], 'string');
    await turn('task.send', {'task_id': id, 'prompt': 'again'});
    expect(definitions(requests.last).map((tool) => tool['name']), ['probe'],
      reason: 'Repeated search must not repeat a loaded schema');

    await client.close();
    await server.close();
    await configure('Updated process inspection', instructions: null);
    server = await AgentServer.startEmbedded(directory: root.path, configPath: config.path, endpoint: endpoint);
    client = await AgentClient.connect(server.uri);
    await turn('task.send', {'task_id': id, 'prompt': 'direct'});
    expect(definitions(requests.last).map((tool) => tool['name']), ['probe', 'probe']);
    expect(definitions(requests.last).last['description'], 'Updated process inspection');
    expect(jsonEncode(requests.last), isNot(contains('unused_schema_')));
    for (var i = 0; i < 2; i++) {
      await turn('task.compact', {'task_id': id});
      await turn('task.send', {'task_id': id, 'prompt': 'direct'});
      expect(definitions(requests.last).map((tool) => tool['name']), ['probe']);
      expect(definitions(requests.last).single['description'], 'Updated process inspection');
      expect(jsonEncode(requests.last), isNot(contains('unused_schema_')));
    }
    expect(requests.every((request) => jsonEncode(request['tools']) == jsonEncode(initialTools)), isTrue);

    // An on-disk task created before discovery has a frozen eager prefix.
    // Seed the public storage format, then resume through the normal server.
    final history = await client.request('history.page', {'task_id': id, 'limit': 500}) as List;
    final legacyConfig = jsonObject(history.firstWhere((event) => event['type'] == 'task.created')['data']);
    legacyConfig['tools'] = (legacyConfig['tools'] as List).where((tool) => tool['name'] != 'tool_search').toList();
    legacyConfig['instructions'] = 'Legacy frozen instructions.';
    final legacyId = newId();
    final store = TaskStore(root.path, legacyId);
    try {
      store.append('task.created', legacyConfig, metadata: {'config': legacyConfig, 'status': 'idle'});
      store.append('input.committed', {'item': ConversationItem.text('user', 'Earlier question').toJson()});
      store.append('model.completed', ModelReply([
        ConversationItem.text('assistant', 'Earlier answer'),
      ], const ModelUsage()).toJson());
    } finally {
      store.close();
    }
    final beforeLegacy = requests.length;
    await turn('task.send', {'task_id': legacyId, 'prompt': 'seed'});
    final legacyPrefix = requests[beforeLegacy];
    expect((legacyPrefix['input'] as List).first['content'], 'Earlier question');
    expect(legacyPrefix['input'][1]['content'][0]['text'], 'Earlier answer');
    expect(definitions(legacyPrefix).map((tool) => tool['type']), ['tool_search']);
    await turn('task.compact', {'task_id': legacyId});
    await turn('task.send', {'task_id': legacyId, 'prompt': 'seed'});
    expect(definitions(requests.last).map((tool) => tool['type']), ['tool_search']);
    expect(requests.skip(beforeLegacy).every((request) => request['instructions'] == 'Legacy frozen instructions.'), isTrue);
    expect(requests.skip(beforeLegacy).every((request) => jsonEncode(request['tools']) == jsonEncode(legacyPrefix['tools'])), isTrue);
  });
}
