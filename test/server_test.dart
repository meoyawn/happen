import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import 'support/thread_names.dart';

void main() {
  group('Codex thread/turn protocol with real agent and SQLite owners', () {
    late Directory root, work;
    late HttpServer provider;
    late AgentServer server;
    late AgentClient client;
    final requests = <Json>[], streaming = <HttpResponse>[];
    late Completer<void> release;
    var failures = 0, rejectSaved = true;

    Future<AgentServer> launch() => AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml', port: 0,
      endpoint: 'http://127.0.0.1:${provider.port}/responses');
    Future<void> until(bool Function() ready) async {
      final timeout = TimeoutCancellationToken(const Duration(seconds: 20));
      try { while (!ready()) { await cancellableDelay(const Duration(milliseconds: 5), timeout); } }
      finally { timeout.cancel(); }
    }
    Future<String> start(String prompt, {String? id, Json options = const {}}) async {
      if (id == null) {
        final created = jsonObject(await client.request('thread/start', {'cwd': work.path, ...options}));
        id = created['thread']['id'] as String;
      }
      await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': prompt}],
        if (options['effort'] != null) 'effort': options['effort']});
      return id;
    }
    Future<Json> finish(String prompt, {String? id, Json options = const {}}) async {
      final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
      await start(prompt, id: id, options: options);
      return done.timeout(const Duration(seconds: 30));
    }
    Future<Json> read(String id, {AgentClient? reader}) async =>
      jsonObject(await (reader ?? client).request('thread/read', {'threadId': id, 'includeTurns': true}));
    List<Json> items(Json page) => [for (final turn in (jsonObject(page['thread'])['turns'] as List).map(jsonObject))
      for (final item in turn['items'] as List) jsonObject(item)];
    List<String> users(Json page) => [for (final item in items(page)) if (item['type'] == 'userMessage')
      (item['content'] as List).where((part) => part['type'] == 'text').map((part) => part['text']).join('\n')];

    setUp(() async {
      root = await Directory.systemTemp.createTemp('native-agent-');
      work = await Directory('${root.path}/work').create();
      await File('${work.path}/numbers.txt').writeAsString('19\n23\n');
      await File('${root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
        'refresh_token': 'fixture', 'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
      requests.clear(); streaming.clear(); failures = 0; rejectSaved = true; release = Completer<void>();
      provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      provider.listen((request) async {
        try {
          final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
          if (await respondToThreadName(request, body)) return;
          requests.add(body);
          final input = (body['input'] as List).map(jsonObject).toList();
          final index = input.lastIndexWhere((item) => item['role'] == 'user' &&
            !jsonEncode(item['content']).contains('The tool runtime was restarted.'));
          final content = input[index]['content'];
          final prompt = content is String ? content : (content as List).where((part) => part['type'] == 'input_text').firstOrNull?['text'] ?? '';
          final outputs = input.skip(index + 1).where((item) => item['type'] == 'custom_tool_call_output').length;
          final hasOutput = outputs >= (prompt == 'long' ? 70 : 1);
          request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
          if (prompt == 'stream' || prompt == 'steering' && hasOutput) {
            request.response.bufferOutput = false; streaming.add(request.response);
            request.response.write('data: {"type":"response.created"}\n\n'); await request.response.flush();
            await release.future; await request.response.close(); return;
          }
          if (prompt == 'retry saved' && hasOutput && rejectSaved) {
            request.response.statusCode = 400; request.response.write('{"error":{"code":"invalid_prompt"}}'); await request.response.close(); return;
          }
          if ({'recover', 'retry saved'}.contains(prompt) && hasOutput && failures++ < 4) {
            request.response.write('data: {"type":"response.output_text.delta","delta":"Abandoned partial answer"}\n\n');
            await request.response.close(); return;
          }
          final output = hasOutput ? <Json>[{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Verified 42 ✓'}]}] : <Json>[
            {'type': 'reasoning', 'id': 'reasoning_fixture', 'summary': <Object?>[], 'encrypted_content': 'opaque-history'},
            {'type': 'custom_tool_call', 'namespace': 'functions', 'call_id': 'call_${requests.length}', 'name': 'exec',
              'input': prompt == 'long' ? 'text("Step $outputs");' : prompt == 'continue' ? 'text(load("sum"));' : '''
                const file = await tools.exec_command({cmd:"cat numbers.txt",login:false});
                const sum = file.output.trim().split(/\\s+/).map(Number).reduce((a,b)=>a+b,0);
                await tools.apply_patch("*** Begin Patch\\n*** Add File: result.txt\\n+"+sum+"\\n*** End Patch");
                store("sum",sum); text(sum);
              '''},
          ];
          if (hasOutput) request.response.write('data: {"type":"response.output_text.delta","delta":"Verified 42 ✓"}\n\n');
          request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed', 'output': output,
            'usage': {'input_tokens': 10, 'output_tokens': 5}}})}\n\n');
          await request.response.close();
        } catch (_) { await request.response.close(); }
      });
      server = await launch(); client = await AgentClient.connect(server.uri);
    });
    tearDown(() async {
      await client.close(); await server.close(); release.complete(); await provider.close(force: true); await root.delete(recursive: true);
    });

    test('completed item notifications reconcile with persisted native history, without replaying tools', () async {
      final live = <String, Json>{};
      final subscription = client.events.stream.listen((event) => applyThreadNotification(live, event));
      addTearDown(subscription.cancel);
      final done = await finish('recover'); expect(done['params']['turn']['status'], 'completed');
      final id = done['params']['threadId'] as String, snapshot = await read(done['params']['threadId'] as String);
      Json payload(Json item) => {for (final key in ['id', 'type', 'text', 'summary', 'tool', 'status']) if (item.containsKey(key)) key: item[key]};
      expect({for (final item in items(snapshot)) item['id']: payload(item)}, live.map((id, item) => MapEntry(id, payload(item))));
      expect(items(snapshot).where((item) => item['type'] == 'agentMessage').single['text'], 'Verified 42 ✓');
      expect(requests, hasLength(6)); expect(await File('${work.path}/result.txt').readAsString(), '42\n');
      final context = jsonObject(await client.request('session.context', {'sessionID': id}));
      expect(context['tokens'], {'input': 10, 'output': 5, 'reasoning': 0, 'cache': {'read': 0, 'write': 0}});
      expect(jsonEncode(context['input']), contains('opaque-history')); expect(snapshot['running'], false);
    });

    test('reconnecting during recovery retains retry status and never promotes abandoned deltas', () async {
      final retrying = client.events.stream.firstWhere((event) => event['method'] == 'happen/turn/retrying' && event['params']['attempt'] == 4);
      final finished = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
      final id = await start('recover'); await retrying.timeout(const Duration(seconds: 15));
      final observer = await AgentClient.connect(server.uri);
      try {
        final snapshot = await read(id, reader: observer); expect(snapshot['running'], true); expect(snapshot['status']['attempt'], 4);
        await finished.timeout(const Duration(seconds: 15));
        expect(jsonEncode(items(await read(id, reader: observer))), isNot(contains('Abandoned partial answer')));
        expect(requests, hasLength(6));
      } finally { await observer.close(); }
    });

    test('archive stops work, cancels the durable inbox, and restores the same thread', () async {
      final id = await start('stream'); await until(() => streaming.isNotEmpty);
      await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Never execute'}], 'delivery': 'queue'});
      final archived = client.events.stream.firstWhere((event) => event['method'] == 'thread/archived');
      await client.request('thread/archive', {'threadId': id}); await archived.timeout(const Duration(seconds: 10));
      final snapshot = await read(id); expect(snapshot['pending'], isEmpty); expect(snapshot['archived'], true); expect(snapshot['running'], false);
      expect(users(snapshot), ['stream']);
      await client.request('thread/unarchive', {'threadId': id});
      expect((await finish('continue', id: id))['params']['turn']['status'], 'completed');
      expect((await read(id))['archived'], false);
    });

    test('withdrawn input stays withdrawn while queued input can steer the active turn', () async {
      final id = await start('stream'); await until(() => streaming.isNotEmpty);
      final removed = newId(), steering = newId();
      for (final (inputId, text) in [(removed, 'Never deliver'), (steering, 'calculate')]) {
        await client.request('turn/start', {'threadId': id, 'clientUserMessageId': inputId,
          'input': [{'type': 'text', 'text': text}], 'delivery': 'queue'});
      }
      await client.request('session.inbox.cancel', {'sessionID': id, 'inboxID': 'msg_$removed'});
      expect(requests, hasLength(1)); expect((await read(id))['pending'].single['prompt'], 'calculate');
      final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
      await client.request('session.inbox.update', {'sessionID': id, 'inboxID': 'msg_$steering', 'delivery': 'steer'});
      await done.timeout(const Duration(seconds: 15));
      expect(users(await read(id)), ['stream', 'calculate']);
      await expectLater(client.request('session.inbox.cancel', {'sessionID': id, 'inboxID': 'msg_$steering'}), throwsStateError);
    });

    test('steering receipt identifies the active turn and committed input', () async {
      final events = <Json>[];
      final subscription = client.events.stream.listen(events.add);
      addTearDown(subscription.cancel);
      final created = jsonObject(await client.request('thread/start', {'cwd': work.path}));
      final id = created['thread']['id'] as String;
      final initial = jsonObject(await client.request('turn/start', {
        'threadId': id, 'input': [{'type': 'text', 'text': 'stream'}],
      }));
      final turnId = initial['turn']['id'];
      for (final method in ['turn/start', 'turn/steer']) {
        final messageId = newId();
        final delivered = client.events.stream.firstWhere((event) => event['method'] == 'item/completed' &&
          event['params']?['item']?['clientId'] == messageId);
        final reply = jsonObject(await client.request(method, {
          'threadId': id, 'clientUserMessageId': messageId,
          'input': [{'type': 'text', 'text': 'stream'}],
          if (method == 'turn/steer') 'expectedTurnId': turnId else 'delivery': 'steer',
        }));
        final committed = await delivered.timeout(const Duration(seconds: 10));
        expect(method == 'turn/steer' ? reply['turnId'] : reply['turn']['id'], turnId);
        expect(committed['params']['turnId'], turnId);
      }
      expect(events.where((event) => event['method'] == 'turn/started'), hasLength(1));
      expect(users(await read(id)), ['stream', 'stream', 'stream']);
    });

    test('turns have no model-step limit, including resumed threads', () async {
      final first = await finish('long'); final id = first['params']['threadId'] as String;
      expect(first['params']['turn']['status'], 'completed');
      expect((await finish('long', id: id))['params']['turn']['status'], 'completed');
      expect(requests, hasLength(142));
      expect((requests.last['input'] as List).where((item) => item['type'] == 'custom_tool_call_output'), hasLength(140));
    });

    test('failed turns retry after restart from durable context without executing completed work twice', () async {
      final failed = await finish('retry saved'); expect(failed['params']['turn']['status'], 'failed');
      final id = failed['params']['threadId'] as String, turnId = failed['params']['turn']['id'];
      await client.close(); await server.close(); rejectSaved = false; server = await launch(); client = await AgentClient.connect(server.uri);
      await expectLater(client.request('turn/start', {'threadId': id, 'input': <Json>[], 'expectedTurnId': 'stale'}), throwsStateError);
      final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
      await client.request('turn/start', {'threadId': id, 'input': <Json>[], 'expectedTurnId': turnId});
      expect((await done.timeout(const Duration(seconds: 15)))['params']['turn']['status'], 'completed');
      expect(requests, hasLength(7)); expect(users(await read(id)), ['retry saved']);
      expect(await File('${work.path}/result.txt').readAsString(), '42\n');
    });

    test('forks share a fixed prefix and portable imports can resume independently', () async {
      final first = await finish('calculate'), id = first['params']['threadId'] as String;
      final fork = jsonObject(await client.request('thread/fork', {'threadId': id, 'lastTurnId': first['params']['turn']['id']}));
      final child = fork['thread']['id'] as String;
      expect(fork['thread']['forkedFromId'], id); expect(fork['thread']['name'], 'Fixture conversation');
      final path = '${root.path}/portable.jsonl';
      await client.request('history.export', {'task_id': child, 'path': path});
      await finish('continue', id: id);
      expect(users(await read(child)), ['calculate']);
      final sourceTurns = (await read(id))['thread']['turns'] as List;
      final sharedItem = sourceTurns.first['items'].first;
      expect((await client.sessionRead('thread/item/read', {'threadId': child,
        'turnId': sourceTurns.first['id'], 'itemId': sharedItem['id']}, cancellation: CancellationToken()))['item']['id'], sharedItem['id']);
      await expectLater(client.sessionRead('thread/item/read', {'threadId': child,
        'turnId': sourceTurns.last['id'], 'itemId': sourceTurns.last['items'].first['id']}, cancellation: CancellationToken()),
        throwsA(predicate((error) => '$error'.contains('Item not found in visible thread history'))));
      final imported = jsonObject(await client.request('history.import', {'path': path, 'operation_id': 'import-operation'}));
      final copy = imported['task_id'] as String;
      expect(await client.request('history.import', {'path': path, 'operation_id': 'import-operation'}), imported);
      final listed = jsonObject(await client.request('thread/list', {'cwd': work.path}));
      expect((listed['data'] as List).map((thread) => thread['id']), unorderedEquals([id, child, copy]));
      expect(users(await read(copy)), ['calculate']);
      expect((await finish('continue', id: child))['params']['turn']['status'], 'completed');
      expect((await finish('continue', id: copy))['params']['turn']['status'], 'completed');
    });

    test('one socket services file search while many threads stream and interrupts only the requested turn', () async {
      final ids = <String>[];
      for (var i = 0; i < 100; i++) { ids.add(await start('stream')); }
      await until(() => streaming.length == 100);
      final deltas = <String, String>{};
      final subscription = client.events.stream.listen((event) {
        if (event['method'] != 'item/agentMessage/delta') return;
        final id = event['params']['threadId'] as String;
        deltas.update(id, (value) => '$value${event['params']['delta']}', ifAbsent: () => event['params']['delta'] as String);
      });
      addTearDown(subscription.cancel);
      for (final response in streaming) { response.write('data: {"type":"response.output_text.delta","delta":"first"}\n\n'); }
      await Future.wait(streaming.map((response) => response.flush())); await until(() => deltas.length == 100);
      final token = CancellationToken();
      try { expect((await client.searchFiles(work.path, 'numbers', cancellation: token))['paths'], ['numbers.txt']); }
      finally { token.cancel(); }
      final snapshot = await read(ids.first);
      final done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
      await client.request('turn/interrupt', {'threadId': ids.first, 'turnId': snapshot['thread']['turns'].last['id']});
      expect((await done.timeout(const Duration(seconds: 10)))['params']['turn']['status'], 'interrupted');
      expect(server.activeTaskCount, 99); expect(deltas.keys, unorderedEquals(ids));
    });

    test('turns outlive 24, 48 and 72 hours until explicitly interrupted', () async {
      await client.close(); await server.close(); final clock = FakeAsync();
      server = await runZoned(launch, zoneSpecification: ZoneSpecification(createTimer: (_, parent, zone, duration, callback) =>
        duration < const Duration(minutes: 10) ? parent.createTimer(zone, duration, callback) : clock.run((_) => Timer(duration, () => zone.run(callback)))));
      client = await AgentClient.connect(server.uri);
      final id = await start('stream'); await until(() => streaming.isNotEmpty);
      final terminals = <Json>[];
      final subscription = client.events.stream.where((event) => event['method'] == 'turn/completed').listen(terminals.add);
      addTearDown(subscription.cancel);
      for (final hours in [24, 48, 72]) {
        clock.elapse(const Duration(hours: 24)); await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(terminals, isEmpty, reason: 'A turn must survive $hours hours'); expect((await read(id))['running'], true);
      }
      final snapshot = await read(id), done = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
      await client.request('turn/interrupt', {'threadId': id, 'turnId': snapshot['thread']['turns'].last['id']});
      expect((await done.timeout(const Duration(seconds: 10)))['params']['turn']['status'], 'interrupted');
    });
  });
}
