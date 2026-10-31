import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('MCP cells filter complete results while model output is bounded', () async {
    final root = await Directory.systemTemp.createTemp('server-mcp-output-');
    final config = File('${root.path}/config.yaml');
    await config.writeAsString(jsonEncode({
      'mcp_servers': {
        'large': {
          'command': Platform.resolvedExecutable,
          'args': [File('test/fixtures/mcp_stdio.dart').absolute.path],
          'legacy_fallback': false,
        },
      },
    }));
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt',
      'access_token': 'fixture',
      'refresh_token': 'fixture',
      'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Json>[];
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requests.add(body);
      final input = (body['input'] as List).map(jsonObject).toList();
      final lastUser = input.lastIndexWhere((item) => item['role'] == 'user');
      final prompt = input[lastUser]['content'];
      final called = input.skip(lastUser + 1).any((item) =>
        item['type'] == 'function_call_output' || item['type'] == 'custom_tool_call_output',
      );
      final output = <Json>[];
      if (called) {
        output.add({
          'type': 'message',
          'role': 'assistant',
          'content': [{'type': 'output_text', 'text': 'Done'}],
        });
      } else if (prompt == 'direct' || prompt == 'error') {
        output.add({
          'type': 'function_call',
          'namespace': 'mcp__large',
          'name': 'probe',
          'arguments': jsonEncode({
            'action': prompt == 'error' ? 'large_error' : 'large',
            'bytes': 128 * 1024,
          }),
          'call_id': 'call_${requests.length}',
        });
      } else {
        output.add({
          'type': 'custom_tool_call',
          'namespace': 'functions',
          'name': 'exec',
          'call_id': 'call_${requests.length}',
          'input': prompt == 'filter' ? '''
            const response = await tools.mcp__large__probe({action: "large", bytes: 3 * 1024 * 1024});
            const data = JSON.parse(response.content.find(c => c.text).text);
            const libraries = data.libraries.filter(l => l.uri === "package:desktop/app.dart");
            store("libraries", libraries);
            store("complete", data.padding.length === 3 * 1024 * 1024 + 8 && data.padding.endsWith("END"));
            text({libraries, structuredContent: response.structuredContent, privateMetadata: response._meta});
          ''' : '''
            const response = await tools.mcp__large__probe({action: "large", bytes: 128 * 1024});
            text(response.content[0].text);
            store("printed", true);
          ''',
        });
      }
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'output': output,
          'usage': {'input_tokens': 100, 'output_tokens': 10},
        },
      })}\n\n');
      await request.response.close();
    });
    final server = await AgentServer.startEmbedded(
      directory: root.path,
      configPath: config.path,
      endpoint: 'http://127.0.0.1:${provider.port}/responses',
    );
    final client = await AgentClient.connect(server.uri);
    addTearDown(() async {
      await client.close();
      await server.close();
      await provider.close(force: true);
      await root.delete(recursive: true);
    });
    Future<List<Json>> turn(String prompt) async {
      final terminal = client.events.stream.firstWhere((event) =>
        ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']),
      );
      await client.request('task.start', {'cwd': root.path, 'prompt': prompt});
      final result = await terminal.timeout(const Duration(seconds: 30));
      expect(result['type'], 'turn.completed', reason: result.toString());
      final history = await client.request('history.page', {'task_id': result['task_id'], 'limit': 100}) as List;
      return history.map(jsonObject).toList();
    }
    Json completed(List<Json> history) => jsonObject(history.singleWhere(
      (event) => event['type'] == 'tool.completed',
    )['data']);
    String modelOutput() => (requests.last['input'] as List).lastWhere((item) =>
      item['type'] == 'function_call_output' || item['type'] == 'custom_tool_call_output',
    )['output'] as String;

    final filtered = completed(await turn('filter'));
    final selected = [{'uri': 'package:desktop/app.dart', 'id': 'app'}];
    expect(filtered['values'], {'libraries': selected, 'complete': true});
    final filteredOutput = jsonDecode(modelOutput())['output'] as List;
    expect(jsonDecode(filteredOutput.single as String), {
      'libraries': selected,
      'structuredContent': {'bytes': 3 * 1024 * 1024},
    });

    final printed = completed(await turn('print'));
    expect(printed['values'], {'printed': true});
    final preview = (jsonDecode(modelOutput())['output'] as List).single as String;
    expect(preview, startsWith('Warning: truncated output'));
    expect(preview, contains('BEGIN'));
    expect(preview, contains('END'));
    expect(utf8.encode(preview).length, lessThan(41000));

    for (final prompt in ['direct', 'error']) {
      final direct = completed(await turn(prompt));
      final part = (direct['item']['content'] as List).single;
      expect(part['is_error'], prompt == 'error');
      final preview = modelOutput();
      expect(preview, startsWith('Warning: truncated output'));
      expect(preview, contains('BEGIN'));
      expect(preview, contains('END'));
      expect(preview, contains('"isError":${prompt == 'error'}'));
      expect(preview, isNot(contains('client-only-metadata')));
      expect(utf8.encode(preview).length, lessThan(41000));
    }
  });

  test('selected tools update during active and idle tasks, compaction, and offline restarts', () async {
    final root = await Directory.systemTemp.createTemp('server-tools-');
    final config = File('${root.path}/config.yaml');
    final fixture = File('test/fixtures/mcp_stdio.dart').absolute.path;
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Json>[];
    final waiting = Completer<void>();
    final responses = <HttpResponse>[];
    var sequence = 0;
    String configuration(String description, {String name = 'dart'}) => jsonEncode({
      'mcp_servers': {
        name: {
          'command': Platform.resolvedExecutable,
          'args': [fixture],
          'env': {'MCP_TOOL_DESCRIPTION': description},
          'legacy_fallback': false,
        },
      },
    });
    final initialConfig = configuration('Initial process probe');
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt',
      'access_token': 'fixture',
      'refresh_token': 'fixture',
      'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requests.add(body);
      final input = (body['input'] as List).map(jsonObject).toList();
      final lastUser = input.lastIndexWhere((item) => item['role'] == 'user');
      final prompt = input[lastUser]['content'];
      final namespace = prompt == 'offline' ? 'mcp__offline' : 'mcp__dart';
      final loaded = input.any((item) =>
        ['additional_tools', 'tool_search_output'].contains(item['type']) &&
        (item['tools'] as List).any((tool) => tool['name'] == namespace),
      );
      if (prompt == 'wait') {
        responses.add(request.response);
        request.response.headers.contentType = ContentType('text', 'event-stream');
        request.response.write('data: {"type":"response.created"}\n\n');
        await request.response.flush();
        waiting.complete();
        return;
      }
      final results = input.skip(lastUser + 1).where((item) =>
        item['type'] == 'function_call_output' || item['type'] == 'custom_tool_call_output',
      ).toList();
      final output = <Json>[];
      if (input.last['type'] == 'compaction_trigger') {
        output.add({'type': 'compaction', 'encrypted_content': 'tool-checkpoint'});
      } else if (prompt == 'configure' && results.isEmpty) {
        final patch = '*** Begin Patch\n*** Add File: ${config.path}\n+$initialConfig\n*** End Patch';
        output.add({
          'type': 'custom_tool_call',
          'namespace': 'functions',
          'name': 'exec',
          'call_id': 'call_${++sequence}',
          'input': 'text(await tools.apply_patch(${jsonEncode(patch)}));',
        });
      } else if (prompt == 'code' && results.isEmpty) {
        output.add({
          'type': 'custom_tool_call',
          'namespace': 'functions',
          'name': 'exec',
          'call_id': 'call_${++sequence}',
          'input': 'text(ALL_TOOLS.find(tool => tool.name === "mcp__dart__probe")); text(await tools.mcp__dart__probe({action:"inspect"}));',
        });
      } else if ((prompt == 'direct' || prompt == 'offline') && results.isEmpty ||
          prompt == 'configure' && results.length == 1) {
        output.add(!loaded ? {
          'type': 'tool_search_call', 'execution': 'client',
          'arguments': {'query': '${namespace}__probe', 'limit': 1},
          'call_id': 'call_${++sequence}',
        } : {
          'type': 'function_call',
          'namespace': namespace,
          'name': 'probe',
          'arguments': '{"action":"inspect"}',
          'call_id': 'call_${++sequence}',
        });
      } else {
        output.add({
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': results.isEmpty ? 'Ready' : results.last['output']},
          ],
        });
      }
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'output': output,
          'usage': {'input_tokens': 100, 'output_tokens': 10},
        },
      })}\n\n');
      await request.response.close();
    });
    final endpoint = 'http://127.0.0.1:${provider.port}/responses';
    var server = await AgentServer.startEmbedded(
      directory: root.path, configPath: config.path, endpoint: endpoint,
    );
    var client = await AgentClient.connect(server.uri);
    addTearDown(() async {
      await client.close();
      await server.close();
      for (final response in responses) {
        unawaited(response.close().catchError((Object _) {}));
      }
      await provider.close(force: true);
      await root.delete(recursive: true);
    });
    Future<Json> turn(String method, Json params) async {
      final completed = client.events.stream.firstWhere((event) =>
        ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']),
      );
      await client.request(method, params);
      final result = await completed.timeout(const Duration(seconds: 15));
      expect(result['type'], 'turn.completed', reason: result.toString());
      return result;
    }
    List<Json> declarations(Json request) => (request['input'] as List)
        .map(jsonObject).where((item) => ['additional_tools', 'tool_search_output'].contains(item['type']) &&
          (item['tools'] as List).isNotEmpty).toList();
    Json spec(Json declaration, {String expectedNamespace = 'mcp__dart'}) {
      if (declaration['type'] == 'additional_tools') expect(declaration['role'], 'developer');
      final namespace = (declaration['tools'] as List).single;
      expect(namespace['type'], 'namespace');
      expect(namespace['name'], expectedNamespace);
      final tool = jsonObject((namespace['tools'] as List).single);
      expect(tool['name'], 'probe');
      expect(tool['type'], 'function');
      expect(tool['parameters']['properties']['action']['type'], 'string');
      return tool;
    }
    Json probeResult(Json terminal) => jsonObject(jsonDecode(
      jsonDecode(terminal['data']['text'] as String)['output']['content'][0]['text'] as String,
    ));

    final seeded = await turn('task.start', {'cwd': root.path, 'prompt': 'seed'});
    final id = seeded['task_id'];
    final initialTools = requests.single['tools'];
    expect(declarations(requests.single), isEmpty);
    final beforeConfigure = requests.length;
    final configured = await turn('task.send', {'task_id': id, 'prompt': 'configure'});
    final firstStep = requests[beforeConfigure];
    final nextStep = requests[beforeConfigure + 1];
    final selectedStep = requests[beforeConfigure + 2];
    expect(declarations(firstStep), isEmpty);
    expect(declarations(nextStep), isEmpty, reason: 'Newly configured schemas stay deferred until search');
    expect(jsonEncode(nextStep['input']), contains('mcp__dart'));
    expect(declarations(selectedStep), hasLength(1));
    expect(spec(declarations(selectedStep).single)['description'], 'Initial process probe');
    expect((nextStep['input'] as List).take((firstStep['input'] as List).length), firstStep['input']);
    final initialDeclaration = declarations(selectedStep).single;
    final statuses = await client.request('mcp.status', {}) as List;
    final firstPid = statuses.single['pid'];
    expect(probeResult(configured)['pid'], firstPid);

    // An idle task keeps its history; changing the same tool appends a new schema.
    final beforeUpdate = requests.length;
    await config.writeAsString(configuration('Updated process probe'), flush: true);
    final updated = await turn('task.send', {'task_id': id, 'prompt': 'direct'});
    final updates = declarations(requests[beforeUpdate]);
    expect(updates, hasLength(2));
    expect(updates.first, initialDeclaration);
    expect(spec(updates.last)['description'], 'Updated process probe');
    final updatedPid = probeResult(updated)['pid'];
    expect(updatedPid, isNot(firstPid));

    // Invalid config retains the last catalog; stable tools are not redeclared.
    await config.writeAsString('mcp_servers: {dart: {command: dart, args: [42]}}', flush: true);
    final code = await turn('task.send', {'task_id': id, 'prompt': 'code'});
    expect(declarations(requests.last), updates);
    final codeOutput = jsonDecode(code['data']['text'] as String)['output'] as List;
    expect(jsonDecode(codeOutput.first as String)['description'], startsWith('Updated process probe'));
    expect(jsonDecode(jsonDecode(codeOutput.last as String)['content'][0]['text'] as String)['pid'], updatedPid);

    // Removals append availability notices and stale calls cannot reach the process.
    await config.writeAsString('mcp_servers: {}\n', flush: true);
    final removed = await turn('task.send', {'task_id': id, 'prompt': 'direct'});
    expect(removed['data']['text'], contains('unavailable'));
    expect(declarations(requests.last), updates);
    final availability = (requests.last['input'] as List).lastWhere((item) => item['role'] == 'developer');
    expect(availability['content'], contains('Removed MCP tools: mcp__dart__probe'));
    expect(availability['content'], contains('unavailable'));
    expect(await client.request('mcp.status', {}), isEmpty);

    final bare = await turn('task.start', {'cwd': root.path, 'prompt': 'seed'});
    final bareId = bare['task_id'];
    final bareRequest = requests.last;
    expect(declarations(bareRequest), isEmpty);

    await config.writeAsString(configuration('Updated process probe'), flush: true);
    await turn('task.compact', {'task_id': id});
    await client.close();
    await server.close();
    server = await AgentServer.startEmbedded(
      directory: root.path, configPath: config.path, endpoint: endpoint,
    );
    client = await AgentClient.connect(server.uri);
    final beforeResume = requests.length;
    final resumed = await turn('task.send', {'task_id': id, 'prompt': 'direct'});
    final restored = requests[beforeResume];
    expect(spec(declarations(restored).single)['description'], 'Updated process probe');
    expect(jsonEncode(restored['input']), contains('tool-checkpoint'));
    expect(probeResult(resumed)['pid'], (await client.request('mcp.status', {}) as List).single['pid']);
    expect(requests.every((request) => jsonEncode(request['tools']) == jsonEncode(initialTools)), isTrue);
    final history = await client.request('history.page', {'task_id': id, 'limit': 500}) as List;
    expect(history.where((event) =>
      event['type'] == 'tool.completed' && (event['data']['item']['tools'] as List? ?? []).isNotEmpty,
    ), hasLength(1));

    // These edits happen after shutdown, so no watcher or previous network
    // isolate can deliver the changes. Resume must diff the durable snapshot.
    final offlineChanges = [
      (
        configuration('Changed while stopped'),
        'direct',
        2,
        'mcp__dart',
        'Changed while stopped',
      ),
      ('mcp_servers: {}\n', 'direct', 2, 'mcp__dart', null),
      (
        configuration('Added while stopped', name: 'offline'),
        'offline',
        3,
        'mcp__offline',
        'Added while stopped',
      ),
    ];
    for (final (contents, prompt, count, namespace, description) in offlineChanges) {
      final previous = requests.last;
      if (prompt == 'offline') {
        await client.request('task.send', {'task_id': bareId, 'prompt': 'wait'});
        await waiting.future.timeout(const Duration(seconds: 15));
      }
      await client.close();
      await server.close();
      await config.writeAsString(contents, flush: true);
      server = await AgentServer.startEmbedded(
        directory: root.path, configPath: config.path, endpoint: endpoint,
      );
      client = await AgentClient.connect(server.uri);
      if (prompt == 'offline') {
        // Resume the task that had no MCPs first, before any other task can
        // refresh the new server's catalog.
        final beforeBare = requests.length;
        final bareResumed = await turn('task.send', {'task_id': bareId, 'prompt': prompt});
        final bareContinuation = requests[beforeBare];
        expect(declarations(bareContinuation), isEmpty);
        expect(spec(declarations(requests.last).single, expectedNamespace: namespace)['description'], description);
        expect((bareContinuation['input'] as List).take((bareRequest['input'] as List).length), bareRequest['input']);
        expect(bareContinuation['tools'], initialTools);
        expect(probeResult(bareResumed)['pid'], (await client.request('mcp.status', {}) as List).single['pid']);
      }
      final before = requests.length;
      final continued = await turn('task.send', {'task_id': id, 'prompt': prompt});
      final request = requests[before];
      final additions = declarations(requests.last);
      expect(additions, hasLength(count));
      expect(additions.take(declarations(previous).length), declarations(previous));
      expect((request['input'] as List).take((previous['input'] as List).length), previous['input']);
      expect(request['tools'], initialTools);
      if (description == null) {
        expect(continued['data']['text'], contains('unavailable'));
        expect(await client.request('mcp.status', {}), isEmpty);
        final notice = (request['input'] as List).lastWhere((item) => item['role'] == 'developer');
        expect(notice['content'], contains('Removed MCP tools: mcp__dart__probe'));
        expect(notice['content'], contains('unavailable'));
      } else {
        expect(spec(additions.last, expectedNamespace: namespace)['description'], description);
        final status = await client.request('mcp.status', {}) as List;
        expect(probeResult(continued)['pid'], status.single['pid']);
      }
    }

  });
}
