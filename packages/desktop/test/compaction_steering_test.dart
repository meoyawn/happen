// Port of Codex core/tests/suite/pending_input.rs::
// steer_during_compaction_is_sent_after_compaction (InstantInterrupt enabled).
// Use the real desktop send path, inference actor and store for both panes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import '../../../test/support/openai_output.dart';
import '../../../test/support/thread.dart';
import '../../../test/support/thread_names.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final side in [false, true]) {
    for (final trigger in ['manual', 'threshold', 'overflow']) {
      test('${side ? 'side' : 'main'} steering during $trigger compaction is sent after compaction', () =>
          HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp('desktop-compaction-steering-');
        final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        AgentServer? server;
        DesktopSession? desktop;
        StreamSubscription<Json>? subscription;
        final release = Completer<void>(), compactStarted = Completer<void>();
        final requests = <Json>[], events = <Json>[];
        var armed = false, triggered = false, autoUsage = 0;
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await subscription?.cancel();
          await desktop?.close();
          await server?.close();
          await provider.close(force: true);
          await root.delete(recursive: true);
        });
        await File('${root.path}/auth.json').writeAsString(jsonEncode({
          'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
          'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
        }));
        provider.listen((request) async {
          final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
          if (await respondToThreadName(request, body)) return;
          requests.add(body);
          final compact = (body['input'] as List).last['type'] == 'compaction_trigger';
          request.response.headers.contentType = ContentType('text', 'event-stream');
          request.response.bufferOutput = false;
          var usage = 100;
          List<Json> output = [{'type': 'message', 'role': 'assistant',
            'content': [{'type': 'output_text', 'text': 'Ready'}]}];
          if (compact) {
            request.response.write('data: ${jsonEncode({'type': 'response.created'})}\n\n');
            await request.response.flush();
            compactStarted.complete();
            await release.future;
            output = [{'type': 'compaction', 'encrypted_content': 'steering-checkpoint'}];
          } else if (armed && !triggered) {
            triggered = true;
            if (trigger == 'overflow') {
              request.response.write('data: ${jsonEncode({'type': 'response.failed', 'response': {
                'status': 'failed', 'error': {'code': 'context_length_exceeded', 'message': 'Fixture overflow'},
              }})}\n\n');
              await request.response.close();
              return;
            }
            if (trigger == 'threshold') {
              usage = autoUsage;
              output = [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec',
                'call_id': 'threshold-tool', 'input': 'text("COMPACTION_TOOL_RECEIPT");'}];
            }
          }
          request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
            'status': 'completed', 'output': output, 'usage': {'input_tokens': usage, 'output_tokens': 10},
          }})}\n\n');
          try { await request.response.close(); } on IOException { /* A failed regression cancels this socket. */ }
        });
        server = await AgentServer.startEmbedded(directory: root.path, configPath: '${root.path}/config.yaml',
          skillsHome: root.path, endpoint: 'http://127.0.0.1:${provider.port}/responses');
        final session = desktop = DesktopSession(await AgentClient.connect(server.uri), await openDesktopDatabase(root.path));
        await session.load();
        await session.addProject(root.path);
        session.chooseModel('gpt-6-astra');
        await session.chooseDeliveryMode('steer');
        subscription = session.client.events.stream.listen(events.add);
        Future<Json> terminal(String? id) => session.client.events.stream.firstWhere((event) =>
          event['method'] == 'turn/completed' && (id == null || event['params']['threadId'] == id))
          .timeout(const Duration(seconds: 15));
        final seeded = terminal(null);
        expect(await session.send('Seed the main conversation'), isTrue, reason: session.error);
        expect((await seeded)['params']['turn']['status'], 'completed');
        final parent = session.task!;
        final target = side ? await session.openSideChat(parent) : parent;
        final parentInput = side ? await contextItems(session.client, parent.id) : null;
        autoUsage = target.contextLimit!.toInt() - 1;
        final requestStart = requests.length, eventStart = events.length;
        armed = true;
        final completed = terminal(target.id);
        unawaited(completed.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
        if (trigger == 'manual') {
          await session.client.request('thread/compact/start', {'threadId': target.id});
        } else {
          expect(await session.send('Continue the active task', target: side ? target : null), isTrue);
        }
        await compactStarted.future.timeout(const Duration(seconds: 10));
        final turnId = target.turns.values.last['id'];
        for (final prompt in ['First steering message', 'Second steering message']) {
          expect(await session.send(prompt, target: side ? target : null), isTrue,
            reason: '${session.error ?? target.sideError}');
        }
        // Round-trip through the agent mailbox after both admitted messages.
        // Keep the provider gate shut: steering must leave compaction running.
        await contextItems(session.client, target.id);
        final compacting = conversation(target).where((entry) => entry.compaction != null).single;
        expect(compacting.compaction!.status, 'running');
        expect(target.pending, hasLength(2));
        expect(target.running, isTrue);
        expect(events.skip(eventStart).where((event) => event['method'] == 'turn/completed'), isEmpty);
        release.complete();
        final done = (await completed)['params']['turn'];
        expect(done['status'], 'completed', reason: '$done');
        expect(done['id'], turnId, reason: 'Steering continues the same turn after committing compaction');
        final active = requests.skip(requestStart).toList();
        final compactions = active.where((body) => (body['input'] as List).last['type'] == 'compaction_trigger').toList();
        expect(compactions, hasLength(1));
        expect(jsonEncode(compactions.single['input']), isNot(contains('steering message')));
        final following = active.skipWhile((body) => body != compactions.single).skip(1).toList();
        expect(following, hasLength(1), reason: 'The first resumed request must receive the pending steering');
        final input = (following.single['input'] as List).map(jsonObject).toList();
        expect(input.where((item) => item['type'] == 'compaction').single['encrypted_content'], 'steering-checkpoint');
        final steers = input.where((item) => item['role'] == 'user').map(openAIMessageText)
          .where((text) => text.endsWith('steering message')).toList();
        expect(steers, ['First steering message', 'Second steering message']);
        if (trigger == 'threshold') {
          expect(jsonEncode(compactions.single['input']), contains('COMPACTION_TOOL_RECEIPT'));
          expect(jsonEncode(input), isNot(contains('COMPACTION_TOOL_RECEIPT')));
        }
        expect(target.pending, isEmpty);
        expect(conversation(target).where((entry) => entry.compaction != null).single.compaction!.status, 'done');
        final lifecycle = events.skip(eventStart).where((event) => event['params']?['threadId'] == target.id &&
          ({'item/started', 'item/completed'}.contains(event['method']) &&
            event['params']['item']['type'] == 'contextCompaction' || event['method'] == 'turn/completed')).toList();
        expect(lifecycle.map((event) => event['method']), ['item/started', 'item/completed', 'turn/completed']);
        expect(lifecycle[1]['params']['item']['status'], 'completed');
        final snapshot = jsonObject(await session.client.request('thread/read', {'threadId': target.id, 'includeTurns': true}));
        expect((snapshot['liveItems'] as List).where((item) => item['type'] == 'contextCompaction'), isEmpty);
        if (side) {
          expect(await contextItems(session.client, parent.id), parentInput);
          expect(parent.running, isFalse);
        }
      }, _LocalHttp()));
    }
  }
}

class _LocalHttp extends HttpOverrides {}
