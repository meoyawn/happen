// Durable-host extension of Codex scenarios_content_filter.rs: guidance and
// delivered output must outlive the short-lived network request and agent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../support/thread_names.dart';

import '../support/thread.dart';

void main() {
  for (final exhausted in [false, true]) {
    test('Codex content-filter guidance is durable before the next request and survives restart: exhausted=$exhausted', () async {
      final root = await Directory.systemTemp.createTemp('codex-filter-');
      final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Json>[];
      var blocked = true;
      late AgentServer server;
      late AgentClient client;
      peer.listen((request) async {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        if (await respondToThreadName(request, body)) return;
        requests.add(body);
        if (requests.length > 1 && blocked) {
          final id = request.headers.value('session-id')!;
          final db = sqlite3.open('${root.path}/tasks/$id/history.sqlite', mode: OpenMode.readOnly);
          try {
            expect(db.select("SELECT count(*) AS n FROM rollout_lines WHERE json_extract(line,'\$.type') IS 'response_item' "
              "AND json_extract(line,'\$.payload.role') IS 'developer' AND line LIKE '%<content_filter_guidance>%'").single['n'],
              requests.length - 1, reason: 'Each retry must wait for durable host admission, not just append to its in-memory body.');
          } finally { db.close(); }
        }
        request.response.headers.contentType = ContentType('text', 'event-stream');
        void send(Json event) => request.response.write('data: ${jsonEncode(event)}\n\n');
        if (requests.length == 1) send({'type': 'response.output_item.done', 'output_index': 0, 'item': {
          'type': 'message', 'id': 'partial-message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'I can help with this topic.'}],
        }});
        if (blocked && (exhausted || requests.length < 3)) {
          send({'type': 'response.incomplete', 'response': {'incomplete_details': {'reason': 'content_filter'}}});
        } else {
          send({'type': 'response.completed', 'response': {'status': 'completed', 'output': [
            {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'A permitted alternative.'}]},
          ]}});
        }
        await request.response.close();
      });
      Future<void> launch() async {
        server = await AgentServer.startEmbedded(directory: root.path, configPath: '${root.path}/config.yaml',
          endpoint: 'http://127.0.0.1:${peer.port}/responses');
        client = await AgentClient.connect(server.uri);
      }
      await File('${root.path}/config.yaml').writeAsString('code_mode_only: false\n');
      await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
        'refresh_token': 'fixture', 'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
      await launch();
      addTearDown(() async { await client.close(); await server.close(); await peer.close(force: true); await root.delete(recursive: true); });
      final id = await createThread(client, {'cwd': root.path});
      final turn = await runTurn(client, id, prompt: 'Help me with this topic.');
      expect(turn['status'], exhausted ? 'failed' : 'completed');
      expect(requests, hasLength(exhausted ? 6 : 3));
      final context = await contextItems(client, id);
      final guidance = context.where((item) => jsonEncode(item).contains('<content_filter_guidance>')).toList();
      expect(guidance, hasLength(exhausted ? 6 : 2));
      expect(guidance.map((item) => item['role']), everyElement('developer'));
      expect(context.where((item) => jsonEncode(item).contains('I can help with this topic.')), hasLength(1));
      for (final (index, body) in requests.indexed.skip(1)) {
        final input = body['input'] as List;
        expect(input.where((item) => jsonEncode(item).contains('<content_filter_guidance>')), hasLength(index));
        expect(input.where((item) => item['id'] == 'partial-message'), hasLength(1));
      }
      await client.close(); await server.close(); await launch();
      expect(await contextItems(client, id), context);
      blocked = false;
      expect((await runTurn(client, id, prompt: 'Continue unrelated authorized work.'))['status'], 'completed');
      expect((requests.last['input'] as List).where((item) => jsonEncode(item).contains('<content_filter_guidance>')), hasLength(guidance.length));
    });
  }
}
