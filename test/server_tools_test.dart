import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import 'support/openai_output.dart';

void main() {
  test('yielded exec resumes through wait and cold resume durably resets native sessions', () async {
    final root = await Directory.systemTemp.createTemp('server-code-cells-');
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Json>[];
    provider.listen((http) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(http).join()));
      requests.add(body);
      final output = <Json>[];
      if (requests.length == 1 || requests.length == 4 || requests.length == 6) {
        output.add({'type': 'custom_tool_call', 'name': 'exec', 'namespace': 'functions', 'call_id': 'cell_${requests.length}',
          'input': requests.length != 1 ? 'text(load("done"));' : '''// @exec: {"yield_time_ms": 0}
text("first"); notify("live notification");
await new Promise(resolve => setTimeout(resolve, 100));
text(await tools.exec_command({cmd: "printf receipt > receipt.txt; printf second", login: false}));
const pending = await tools.exec_command({cmd: "read value", shell: "/bin/sh", login: false, yield_time_ms: 250});
store("commandSession", pending.session_id);
store("done", true);
setTimeout(() => { throw new Error("discarded timer"); }, 60000);
'''});
      } else if (requests.length == 2) {
        final input = (body['input'] as List).map(jsonObject);
        final status = input.where((item) => item['type'] == 'custom_tool_call_output')
          .expand((item) => (item['output'] as List).map(jsonObject)).map((part) => part['text']).whereType<String>()
          .firstWhere((text) => text.startsWith('Script running with cell ID '));
        final id = RegExp(r'Script running with cell ID ([^\n]+)').firstMatch(status)![1]!;
        output.add({'type': 'function_call', 'name': 'wait', 'call_id': 'observe',
          'arguments': jsonEncode({'cell_id': id, 'yield_time_ms': 1000})});
      } else {
        output.add({'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Done'}]});
      }
      http.response.headers.contentType = ContentType('text', 'event-stream');
      http.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
        'status': 'completed', 'output': output, 'usage': {'input_tokens': 100, 'output_tokens': 10},
      }})}\n\n');
      await http.response.close();
    });
    AgentServer? server;
    AgentClient? client;
    addTearDown(() async {
      await client?.close(); await server?.close(); await provider.close(force: true); await root.delete(recursive: true);
    });
    Future<void> start() async {
      server = await AgentServer.startEmbedded(directory: root.path, endpoint: 'http://127.0.0.1:${provider.port}/responses');
      client = await AgentClient.connect(server!.uri);
    }
    Future<String> turn(String? id) async {
      final terminal = client!.events.stream.firstWhere((event) =>
        ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']));
      await client!.request(id == null ? 'task.start' : 'task.send', {
        if (id == null) 'cwd': root.path else 'task_id': id, 'prompt': id == null ? 'Start' : 'Continue',
      });
      final result = await terminal.timeout(const Duration(seconds: 10));
      expect(result['type'], 'turn.completed', reason: result.toString());
      return result['task_id'] as String;
    }
    await start();
    final id = await turn(null);
    expect(await File('${root.path}/receipt.txt').readAsString(), 'receipt');
    final finalInput = (requests[2]['input'] as List).map(jsonObject).toList();
    final notices = finalInput.where((item) => item['type'] == 'custom_tool_call_output' &&
      item['name'] == 'exec' && item['output'] == 'live notification');
    expect(notices, hasLength(1));
    expect(jsonEncode(finalInput.last), contains('second'));
    expect(jsonEncode(finalInput.last), isNot(contains('first')));
    expect(jsonEncode(finalInput), isNot(contains('The tool runtime was restarted.')));
    await client!.close(); client = null; await server!.close(); server = null;
    await start();
    await turn(id);
    expect(jsonEncode(requests[3]['input']), contains('live notification'));
    expect(jsonEncode(requests[3]['input']), contains('The tool runtime was restarted.'));
    expect(jsonEncode(requests[3]['input']), contains('Do not reuse earlier session or cell IDs.'));
    expect(printedOpenAIOutput((requests.last['input'] as List).last['output']), ['true']);
    final history = (await client!.request('history.page', {'task_id': id}) as List).map(jsonObject).toList();
    final resets = history.where((event) => event['type'] == 'input.committed' &&
      event['data']['item']?['native']?['harness']?['reason'] == 'tool_runtime_restarted');
    expect(resets, hasLength(1), reason: 'The reset must be committed before the resumed model request');
    await turn(id);
    final warmHistory = (await client!.request('history.page', {'task_id': id}) as List).map(jsonObject);
    expect(warmHistory.where((event) => event['type'] == 'input.committed' &&
      event['data']['item']?['native']?['harness']?['reason'] == 'tool_runtime_restarted'), hasLength(1),
      reason: 'A live runtime must survive turn completion without another reset');
  });

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
      final prompt = openAIMessageText(input[lastUser]);
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
    List<String> modelOutput() => printedOpenAIOutput((requests.last['input'] as List).lastWhere((item) =>
      item['type'] == 'function_call_output' || item['type'] == 'custom_tool_call_output',
    )['output']);

    final filtered = completed(await turn('filter'));
    final selected = [{'uri': 'package:desktop/app.dart', 'id': 'app'}];
    expect(filtered['values'], {'libraries': selected, 'complete': true});
    final filteredOutput = modelOutput();
    expect(jsonDecode(filteredOutput.single), {
      'libraries': selected,
      'structuredContent': {'bytes': 3 * 1024 * 1024},
    });

    final printed = completed(await turn('print'));
    expect(printed['values'], {'printed': true});
    final preview = modelOutput().single;
    expect(preview, startsWith('Warning: truncated output'));
    expect(preview, contains('BEGIN'));
    expect(preview, contains('END'));
    expect(utf8.encode(preview).length, lessThan(41000));

  });

}
