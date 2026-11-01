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

  });

}
