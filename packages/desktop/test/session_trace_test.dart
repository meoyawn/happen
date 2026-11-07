import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:desktop/session_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import '../../../test/support/thread_names.dart';

void main() {
  for (final transport in ['http', 'websocket']) {
    testWidgets('$transport tracing is opt-in per session across sockets, isolates, and queued turns', (tester) async {
      late Directory root;
      late HttpServer provider;
      late AgentServer server;
      late DesktopSession session;
      final sockets = <WebSocket>[];
      final requests = <Json>[];
      late Completer<void> arrived, release;
      late List<Completer<void>> completed;
      final observed = <Json>[];
      var turns = 0;
      StreamSubscription<Json>? events;
      // A headless client may select WebSocket for a thread that the desktop
      // then opens. New desktop drafts use the provider's default transport.
      Future<void> selectConfiguredThread() async {
        if (transport == 'http') return;
        final created = jsonObject(await session.client.request('thread/start', {
          'cwd': root.path, 'model': session.modelId, 'tracing': session.currentDraft.tracing,
          'settings': {'transport': transport},
        }));
        final project = session.projects.single;
        final task = DesktopTask(created['thread']['id'] as String, 'Configured thread');
        project.tasks.add(task);
        await session.select(project, task);
      }
      await tester.runAsync(() => HttpOverrides.runWithHttpOverrides(() async {
        arrived = Completer<void>();
        release = Completer<void>();
        completed = List.generate(4, (_) => Completer<void>());
        root = await Directory.systemTemp.createTemp('session-trace-');
        provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        await File('${root.path}/auth.json').writeAsString(jsonEncode({
          'type': 'chatgpt', 'access_token': 'fixture-access-secret', 'refresh_token': 'fixture-refresh-secret',
          'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
        }));
        Future<String> reply(Json body) async {
          if (threadNameReply(body) case final events?) return jsonEncode(events.single);
          requests.add(body);
          if (requests.length == 2) {
            arrived.complete();
            await release.future;
          }
          return jsonEncode({'type': 'response.completed', 'response': {
            'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
              'content': [{'type': 'output_text', 'text': 'Private model reply'}]}],
          }});
        }
        provider.listen((request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            final socket = await WebSocketTransformer.upgrade(request);
            sockets.add(socket);
            socket.listen((raw) async => socket.add(await reply(jsonObject(jsonDecode(raw as String)))));
          } else {
            final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
            request.response.headers.contentType = ContentType('text', 'event-stream');
            request.response.bufferOutput = false;
            request.response.write('data: ${await reply(body)}\n\n');
            // A model can finish before its SSE connection reaches EOF.
            await request.response.flush();
          }
        });
        server = await AgentServer.start(directory: root.path, port: 0,
          configPath: '${root.path}/config.yaml', skillsHome: root.path,
          endpoint: 'http://127.0.0.1:${provider.port}/responses');
        session = DesktopSession(await AgentClient.connect(server.uri), await openDesktopDatabase(root.path),
          attachmentDirectory: '${root.path}/attachments');
        await session.load();
        await session.addProject(root.path);
        session.chooseModel('gpt-6-astra');
        await session.chooseDeliveryMode('queue');
        void watch() {
          events = session.client.events.stream.listen((event) {
            observed.add(event);
            if (event['method'] == 'turn/completed' && event['params']['turn']['status'] == 'completed') {
              completed[turns++].complete();
            } else if (event['method'] == 'turn/completed' && event['params']['turn']['status'] == 'failed') {
              completed[turns].completeError(StateError('$event'));
            }
          });
        }
        watch();
        expect(session.currentDraft.tracing, isFalse);
        await selectConfiguredThread();
        expect(await session.send('Private untraced prompt'), isTrue, reason: session.error);
        await completed[0].future.timeout(const Duration(seconds: 20));
        final untracedID = session.task!.id;
        expect(await session.send('/side'), isTrue, reason: session.error);
        final side = session.sideChats.values.single;
        expect(side.tracing, isFalse);
        expect((await session.client.sessionRead('thread/read', {'threadId': side.id},
          cancellation: CancellationToken()))['configuration']['tracing'], isFalse);
        await session.client.request('session.side.close', {'sessionID': side.id});
        expect((await session.client.traceStatus(untracedID, cancellation: CancellationToken()))['categories'], isEmpty);
        expect((await session.client.tracePage(untracedID, cancellation: CancellationToken()))['events'], isEmpty);
        for (final file in ['telemetry.sqlite', 'telemetry-desktop.sqlite']) {
          expect(await File('${root.path}/$file').exists(), isFalse,
            reason: 'An unchecked session and its trace reads must not create a recorder');
        }
        expect(observed.where((event) => event['params']?['threadId'] == untracedID)
          .any((event) => event.containsKey('_trace')), isFalse);
        session.newSession();
        session.chooseTracing(true);
        final draftID = session.currentDraft.id;
        await events!.cancel();
        await session.close();
        session = DesktopSession(await AgentClient.connect(server.uri), await openDesktopDatabase(root.path),
          attachmentDirectory: '${root.path}/attachments');
        await session.load();
        expect(session.currentDraft.id, draftID);
        expect(session.currentDraft.tracing, isTrue, reason: 'Opt-in must survive restoring the draft');
        watch();
      }, _LocalHttp()));
      addTearDown(() => tester.runAsync(() async {
        if (!release.isCompleted) release.complete();
        await events?.cancel();
        await session.close();
        await server.close();
        for (final socket in sockets) { await socket.close(); }
        await provider.close(force: true);
        await root.delete(recursive: true);
      }));
      await tester.pumpWidget(MaterialApp(home: ListenableBuilder(listenable: session,
        builder: (context, _) => Text(session.task?.streamingText ?? 'Ready'))));
      await tester.runAsync(() async {
        await selectConfiguredThread();
        expect(await session.send('Private first prompt'), isTrue, reason: session.error);
        await arrived.future.timeout(const Duration(seconds: 15));
        expect(await session.send('Private queued prompt'), isTrue, reason: session.error);
        release.complete();
        await completed[2].future.timeout(const Duration(seconds: 20));
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(requests, hasLength(3));
      expect(jsonEncode(requests), contains('Private queued prompt'));
      expect(session.task!.pending, isEmpty);
      final sessionID = session.task!.id;
      expect(session.task!.tracing, isTrue);
      await tester.runAsync(() async {
        expect(await session.send('/side'), isTrue, reason: session.error);
        final side = session.sideChats.values.single;
        expect(side.tracing, isTrue);
        expect((await session.client.sessionRead('thread/read', {'threadId': side.id},
          cancellation: CancellationToken()))['configuration']['tracing'], isTrue);
        await session.client.request('session.side.close', {'sessionID': side.id});
      });
      final encoded = (await tester.runAsync(() async {
        final file = await saveSessionTrace(session.client, await session.tracing,
          title: 'Session', sessionID: sessionID, downloadsDirectory: Directory('${root.path}/Downloads'),
          cancellation: CancellationToken());
        return file.readAsString();
      }))!;
      final document = jsonDecode(encoded) as Map;
      expect(document['metadata']['sessionID'], sessionID);
      final records = (document['traceEvents'] as List).map(jsonObject).toList();
      // Each submit must retain one identity through all owners and its return
      // to desktop, even when the server defers execution behind another turn.
      final submissions = records.where((event) => event['name'] == 'desktop.submit' && event['ph'] == 'b')
        .map((event) => event['args']['trace_id']).toSet();
      expect(submissions, hasLength(2));
      for (final id in submissions) {
        final trace = records.where((event) => event['args']['trace_id'] == id).toList();
        expect(trace.map((event) => event['args']['service']).toSet(),
          containsAll(['desktop', 'server', 'storage', 'agent', 'openai']));
        expect(trace.where((event) => event['name'] == 'server.turn' && event['ph'] == 'b'), hasLength(1));
        expect(trace.any((event) => event['cat'] == 'sqlite' && event['ph'] == 'e'
          && event['args']['duration_us'] is int), isTrue);
        expect(trace.any((event) => event['name'] == 'desktop.event.apply'), isTrue);
        expect(trace.any((event) => event['name'] == 'openai.responses'), isTrue);
        if (transport == 'http') {
          expect(trace.any((event) => event['name'] == 'http.POST'), isTrue);
          final bodies = trace.where((event) => event['name'] == 'http.body' && event['ph'] == 'e').toList();
          expect(bodies, isNotEmpty);
          expect(bodies.map((body) => body['args']['status']), everyElement('ok'),
            reason: 'Consuming a completed response is successful even before EOF');
        } else {
          expect(trace.any((event) => event['name'] == 'openai.websocket.receive'), isTrue);
        }
      }
      expect(records.any((event) => event['name'] == 'desktop.frame.presented'), isTrue);
      final starts = {for (final event in records.where((event) => event['ph'] == 'b')) event['id']: event};
      for (final start in starts.values) {
        if (start['args']['parent_span_id'] case final String parent) expect(starts, contains(parent));
      }
      final sends = records.where((event) => event['ph'] == 's').map((event) => event['id']).toSet();
      final receives = records.where((event) => event['ph'] == 'f').map((event) => event['id']).toSet();
      expect(receives, sends, reason: 'Every recorded transport send must have its matching receive');
      for (final secret in ['fixture-access-secret', 'fixture-refresh-secret',
        'Private first prompt', 'Private queued prompt', 'Private model reply']) {
        expect(encoded, isNot(contains(secret)));
      }
      final empty = await tester.runAsync(() => session.client.tracePage('another-session',
        cancellation: CancellationToken()));
      expect(empty!['events'], isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => HttpOverrides.runWithHttpOverrides(() async {
        session.newSession();
        expect(session.currentDraft.tracing, isFalse, reason: 'Tracing is not a sticky preference');
        await selectConfiguredThread();
        expect(await session.send('Private untraced prompt after recording'), isTrue, reason: session.error);
        await completed[3].future.timeout(const Duration(seconds: 20));
        final untracedID = session.task!.id;
        expect((await session.client.traceStatus(untracedID, cancellation: CancellationToken()))['categories'], isEmpty);
        expect((await (await session.tracing).status(untracedID, cancellation: CancellationToken()))['categories'], isEmpty);
        expect(observed.where((event) => event['params']?['threadId'] == untracedID)
          .any((event) => event.containsKey('_trace')), isFalse);
        await events!.cancel();
        await session.close();
        session = DesktopSession(await AgentClient.connect(server.uri), await openDesktopDatabase(root.path),
          attachmentDirectory: '${root.path}/attachments');
        await session.load();
        final traced = session.projects.expand((project) => project.tasks).singleWhere((task) => task.id == sessionID);
        final untraced = session.projects.expand((project) => project.tasks).singleWhere((task) => task.id == untracedID);
        expect(traced.tracing, isTrue, reason: 'The durable session inventory must restore its tracing choice');
        expect(untraced.tracing, isFalse);
        final store = await session.tracing;
        final before = await store.status(sessionID, cancellation: CancellationToken());
        await session.loadHistory(traced);
        final after = await store.status(sessionID, cancellation: CancellationToken());
        expect(after['categories']['websocket'], greaterThan(before['categories']['websocket'] as int),
          reason: 'Reopened traced sessions must also trace their new requests');
      }, _LocalHttp()));
    });
  }
}

class _LocalHttp extends HttpOverrides {}
