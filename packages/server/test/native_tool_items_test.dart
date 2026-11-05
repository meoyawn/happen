// Codex core/tests/suite/{apply_patch_serialization,view_image,pending_input}.rs
// and tools/events.rs. Real model->agent->host effects, native notifications,
// canonical SQLite and cold replay; not hand-built projection payloads.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

void main() {
  late Directory root;
  late HttpServer provider;
  late AgentServer server;
  late AgentClient client;
  late StreamSubscription<Json> subscription;
  final events = <Json>[], requests = <Json>[];
  var tool = 'apply_patch', namespace = 'functions', nested = false;
  Object? arguments;
  Future<void> launch() async {
    server = await AgentServer.start(directory: root.path, port: 0, skillsHome: root.path, configPath: '${root.path}/config.yaml',
      endpoint: 'http://127.0.0.1:${provider.port}/responses');
    client = await AgentClient.connect(server.uri); subscription = client.events.stream.listen(events.add);
  }
  Future<Json> read(String id) async => jsonObject(await client.request('thread/read', {'threadId': id, 'includeTurns': true}));
  List<Json> items(Json page) => [for (final turn in page['thread']['turns'] as List) for (final item in turn['items'] as List) jsonObject(item)];
  Future<String> begin() async {
    final id = jsonObject(await client.request('thread/start', {'cwd': root.path}))['thread']['id'] as String;
    await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Run the selected tool.'}]}); return id;
  }
  Future<void> coldReplay(String id, Json item) async {
    await subscription.cancel(); await client.close(); await server.close(); await launch();
    expect(items(await read(id)).singleWhere((i) => i['id'] == item['id']), item);
    expect(requests, hasLength(2), reason: 'Cold read cannot repeat host effects or inference.');
  }
  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-item-effects-'); events.clear(); requests.clear(); nested = false; tool = 'apply_patch'; namespace = 'functions';
    await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture',
      'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    await File('${root.path}/config.yaml').writeAsString('{"code_mode_only":false}');
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      requests.add(jsonObject(jsonDecode(await utf8.decoder.bind(request).join())));
      final Json call = nested ? {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'cell',
        'input': tool == 'view_image' ? 'image(await tools.view_image(${jsonEncode(arguments)}));' : 'await tools.apply_patch(${jsonEncode(arguments)});'}
        : arguments is String ? {'type': 'custom_tool_call', 'namespace': namespace, 'name': tool, 'call_id': 'native', 'input': arguments}
        : {'type': 'function_call', 'namespace': namespace, 'name': tool, 'call_id': 'native', 'arguments': jsonEncode(arguments)};
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed', 'output': [
        if (requests.length == 1) call else {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Done'}]},
      ]}})}\n\n'); await request.response.close();
    });
    await launch();
  });
  tearDown(() async { await subscription.cancel(); await client.close(); await server.close(); await provider.close(force: true); await root.delete(recursive: true); });

  for (final code in [false, true]) {
    for (final action in ['add', 'update', 'move', 'delete', 'write failure']) {
      test('native file-change lifecycle/cold replay follows actual $action effects, nested=$code', () async {
        nested = code; await File('${root.path}/before.txt').writeAsString('before\n');
        if (action == 'write failure') await File('${root.path}/blocked').writeAsString('not a directory');
        arguments = switch (action) {
          'add' => '*** Begin Patch\n*** Add File: after.txt\n+after\n*** End Patch',
          'delete' => '*** Begin Patch\n*** Delete File: before.txt\n*** End Patch',
          'write failure' => '*** Begin Patch\n*** Add File: blocked/after.txt\n+after\n*** End Patch',
          _ => '*** Begin Patch\n*** Update File: before.txt\n${action == 'move' ? '*** Move to: moved.txt\n' : ''}@@\n-before\n+after\n*** End Patch',
        };
        final done = client.events.stream.firstWhere((e) => e['method'] == 'turn/completed'); final id = await begin(); await done.timeout(const Duration(seconds: 15));
        final lifecycle = events.where((e) => e['params']?['item']?['type'] == 'fileChange').toList();
        expect(lifecycle.map((e) => e['method']), ['item/started', 'item/completed']);
        final started = jsonObject(lifecycle.first['params']['item']), completed = jsonObject(lifecycle.last['params']['item']);
        expect(started['status'], 'inProgress'); expect(completed['status'], action == 'write failure' ? 'failed' : 'completed');
        expect(started['id'], completed['id']); expect(completed['changes'], hasLength(1));
        expect(completed['changes'].single['kind']['type'], action == 'add' || action == 'write failure' ? 'add' : action == 'delete' ? 'delete' : 'update');
        expect(completed['changes'].single['diff'], contains(action == 'delete' ? 'before' : 'after'));
        if (action == 'move') expect(completed['changes'].single['kind']['move_path'], '${root.path}/moved.txt');
        if (action == 'add' || action == 'update' || action == 'move') expect(await File('${root.path}/${action == 'add' ? 'after.txt' : action == 'move' ? 'moved.txt' : 'before.txt'}').readAsString(), 'after\n');
        if (action == 'delete' || action == 'move') expect(await File('${root.path}/before.txt').exists(), false);
        if (action == 'write failure') expect(await File('${root.path}/blocked').readAsString(), 'not a directory');
        final page = await read(id); expect(items(page).singleWhere((i) => i['id'] == completed['id']), completed);
        expect(items(page).where((i) => i['type'] == 'dynamicToolCall' && i['tool'] == 'apply_patch'), isEmpty, reason: 'No parallel generic/native item implementation.');
        await coldReplay(id, completed);
      });
    }
    for (final validity in ['valid', 'missing', 'directory', 'invalid bytes', 'invalid detail']) {
      test('native image-view validates before announcement and replays only real images: $validity/nested=$code', () async {
        nested = code; tool = 'view_image';
        await File('${root.path}/image.png').writeAsBytes(base64Decode(png));
        await File('${root.path}/invalid.png').writeAsString('PRIVATE-NOT-IMAGE');
        arguments = {'path': switch (validity) {'missing' => 'missing.png', 'directory' => '.', 'invalid bytes' => 'invalid.png', _ => 'image.png'},
          if (validity == 'invalid detail') 'detail': 'unsupported'};
        final done = client.events.stream.firstWhere((e) => e['method'] == 'turn/completed'); final id = await begin(); await done.timeout(const Duration(seconds: 15));
        final lifecycle = events.where((e) => e['params']?['item']?['type'] == 'imageView').toList();
        if (validity != 'valid') {
          expect(lifecycle, isEmpty); expect(jsonEncode(requests.last['input']), isNot(contains(base64Encode(utf8.encode('PRIVATE-NOT-IMAGE'))))); return;
        }
        expect(lifecycle.map((e) => e['method']), ['item/started', 'item/completed']);
        final completed = jsonObject(lifecycle.last['params']['item']); expect(completed['path'], '${root.path}/image.png');
        expect(jsonEncode(requests.last['input']), contains('data:image/png;base64,$png'));
        expect(items(await read(id)).singleWhere((i) => i['id'] == completed['id']), completed);
        await coldReplay(id, completed);
      });
    }
  }

  for (final mode in ['normal', 'steering', 'Stop']) {
    test('native sleep lifecycle survives $mode without a generic MCP item or leaked timer', () async {
      tool = 'sleep'; namespace = 'clock'; arguments = {'duration_ms': mode == 'normal' ? 1 : 3600000};
      final done = client.events.stream.firstWhere((e) => e['method'] == 'turn/completed');
      final started = client.events.stream.firstWhere((e) => e['method'] == 'item/started' && e['params']['item']['type'] == 'sleep');
      final id = await begin(); final start = await started.timeout(const Duration(seconds: 5));
      if (mode == 'Stop') await client.request('turn/interrupt', {'threadId': id, 'turnId': start['params']['turnId']});
      if (mode == 'steering') await client.request('turn/steer', {'threadId': id, 'expectedTurnId': start['params']['turnId'], 'input': [{'type': 'text', 'text': 'Continue now.'}]});
      final terminal = await done.timeout(const Duration(seconds: 10));
      expect(terminal['params']['turn']['status'], mode == 'Stop' ? 'interrupted' : 'completed');
      final lifecycle = events.where((e) => e['params']?['item']?['type'] == 'sleep').toList();
      expect(lifecycle.map((e) => e['method']), ['item/started', 'item/completed']);
      final completed = jsonObject(lifecycle.last['params']['item']); expect(completed['durationMs'], mode == 'normal' ? 1 : 3600000);
      expect(items(await read(id)).singleWhere((i) => i['id'] == completed['id']), completed);
      if (mode != 'Stop') { expect(requests, hasLength(2)); await coldReplay(id, completed); }
    });
  }
}
