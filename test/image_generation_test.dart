import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import 'support/thread.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

void main() {
  test('imagegen generates, edits, publishes image results and cancels before publishing an artifact', () async {
    final root = await Directory.systemTemp.createTemp('imagegen-contract-');
    final reference = await File('${root.path}/reference.png').writeAsBytes(base64Decode(_png));
    final auth = File('${root.path}/auth.json');
    await auth.writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final images = <Json>[], inference = <Json>[], held = <HttpResponse>[];
    final imageStarted = Completer<void>();
    peer.listen((http) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(http).join()));
      if (http.uri.path.endsWith('/responses')) {
        inference.add(body);
        final input = (body['input'] as List).map(jsonObject).toList();
        final user = input.lastIndexWhere((item) => item['role'] == 'user');
        final content = input[user]['content'];
        final prompt = content is String ? content : (content as List).where((part) => part['type'] == 'input_text').map((part) => part['text']).join();
        final called = input.skip(user + 1).any((item) => item['type'] == 'custom_tool_call_output');
        final args = {'prompt': prompt, 'transparent_background': prompt == 'generate',
          if (prompt == 'edit-file') 'referenced_image_paths': [reference.path],
          if (prompt == 'edit-recent') 'num_last_images_to_include': 1};
        http.response.headers.contentType = ContentType('text', 'event-stream');
        http.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
          'status': 'completed', 'usage': {'input_tokens': 100, 'output_tokens': 10},
          'output': [if (!called) {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec',
            'call_id': 'image_${inference.length}', 'input': 'generatedImage(await tools.image_gen__imagegen(${jsonEncode(args)}));'}
          else {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Done'}]}],
        }})}\n\n');
        await http.response.close();
      } else {
        images.add({'path': http.uri.path, 'body': body, 'authorization': http.headers.value('authorization'),
          'account': http.headers.value('chatgpt-account-id'), 'turn': http.headers.value('x-codex-image-turn-id')});
        if (body['prompt'] == 'cancel') { held.add(http.response); imageStarted.complete(); return; }
        http.response.headers.contentType = ContentType.json;
        http.response.headers.set('x-codex-imagegen-request-id', 'fixture-image-request');
        http.response.write(jsonEncode({'created': 1, 'background': body['background'],
          'data': [{'b64_json': _png, 'generation_id': 'fixture-generation'}]}));
        await http.response.close();
      }
    });
    final config = File('${root.path}/config.yaml');
    await config.writeAsString(jsonEncode({'providers': {'openai': {'settings': {'image_generation': true, 'web_search': 'disabled'}}}}));
    final server = await AgentServer.startEmbedded(directory: root.path, configPath: config.path,
      endpoint: 'http://127.0.0.1:${peer.port}/responses');
    final client = await AgentClient.connect(server.uri);
    addTearDown(() async {
      await client.close(); await server.close();
      for (final response in held) { unawaited(response.close().catchError((Object _) {})); }
      await peer.close(force: true); await root.delete(recursive: true);
    });
    Future<String> run(String prompt) async {
      final id = await createThread(client, {'cwd': root.path});
      final completed = await runTurn(client, id, prompt: prompt, settings: {'input': [
        {'type': 'text', 'text': prompt},
        if (prompt == 'edit-recent') {'type': 'image', 'name': 'reference', 'path': reference.path},
      ]});
      expect(completed['status'], 'completed', reason: completed.toString());
      return id;
    }
    for (final prompt in ['generate', 'edit-file', 'edit-recent']) {
      final before = images.length;
      final id = await run(prompt);
      expect(images, hasLength(before + 1));
      final request = images.last;
      expect(request['path'], prompt == 'generate' ? '/images/generations' : '/images/edits');
      expect(request['authorization'], 'Bearer fixture');
      expect(request['account'], 'fixture');
      expect(request['turn'], matches(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'));
      expect(request['body'], {'prompt': prompt, 'background': prompt == 'generate' ? 'transparent' : 'opaque',
        'model': 'gpt-image-2', 'quality': 'auto', 'size': 'auto',
        if (prompt != 'generate') 'images': [{'image_url': 'data:image/png;base64,$_png'}]});
      final result = (inference.last['input'] as List).lastWhere((item) => item['type'] == 'custom_tool_call_output');
      final content = result['output'] as List;
      expect(content.map((part) => part['type']), ['input_text', 'input_image', 'input_text']);
      expect(content[1]['image_url'], 'data:image/png;base64,$_png');
      final folder = Directory('${root.path}/generated_images/$id');
      final file = (await folder.list().toList()).whereType<File>().single;
      expect(await file.readAsBytes(), base64Decode(_png));
      expect(content[2]['text'], contains(file.path));
      final history = jsonObject(await client.request('thread/items/list', {'threadId': id}));
      final record = (history['data'] as List).lastWhere((entry) => entry['item']['type'] == 'dynamicToolCall')['item'];
      expect((record['contentItems'] as List).where((part) => part['type'] == 'inputImage'), hasLength(1),
        reason: 'The UI receives a real inline image, not base64 prose');
    }
    final id = await createThread(client, {'cwd': root.path});
    final done = runTurn(client, id, prompt: 'cancel');
    await imageStarted.future.timeout(const Duration(seconds: 10));
    final snapshot = jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
    await client.request('turn/interrupt', {'threadId': id, 'turnId': (snapshot['thread']['turns'] as List).last['id']});
    expect((await done)['status'], 'interrupted');
    expect(Directory('${root.path}/generated_images/$id').existsSync(), isFalse);
    expect((await Directory('${root.path}/generated_images').list(recursive: true).toList())
      .where((file) => file.path.contains('.partial-')), isEmpty);
  });
}
