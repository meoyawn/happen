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

void main() {
  for (final transport in ['http', 'websocket']) {
    testWidgets('$transport session trace crosses real sockets and isolates, including a queued turn', (tester) async {
      late Directory root;
      late HttpServer provider;
      late AgentServer server;
      late DesktopSession session;
      final sockets = <WebSocket>[];
      final requests = <Json>[];
      late Completer<void> arrived, release, completed;
      var turns = 0;
      StreamSubscription<Json>? events;
      await tester.runAsync(() => HttpOverrides.runWithHttpOverrides(() async {
        arrived = Completer<void>();
        release = Completer<void>();
        completed = Completer<void>();
        root = await Directory.systemTemp.createTemp('session-trace-');
        provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        await File('${root.path}/config.yaml').writeAsString(jsonEncode({
          'providers': {'openai': {'settings': {'transport': transport}}},
        }));
        await File('${root.path}/auth.json').writeAsString(jsonEncode({
          'type': 'chatgpt', 'access_token': 'fixture-access-secret', 'refresh_token': 'fixture-refresh-secret',
          'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
        }));
        Future<String> reply(Json body) async {
          requests.add(body);
          if (requests.length == 1) {
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
        await session.tracing;
        await session.load();
        await session.addProject(root.path);
        session.chooseModel('gpt-6-astra');
        session.deliveryMode = 'queue';
        events = session.client.events.stream.listen((event) {
          if (event['type'] == 'session.execution.succeeded') {
            if (++turns == 2) completed.complete();
          } else if (event['type'] == 'session.execution.failed' && !completed.isCompleted) {
            completed.completeError(StateError('$event'));
          }
        });
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
        expect(await session.send('Private first prompt'), isTrue, reason: session.error);
        await arrived.future.timeout(const Duration(seconds: 15));
        expect(await session.send('Private queued prompt'), isTrue, reason: session.error);
        release.complete();
        await completed.future.timeout(const Duration(seconds: 20));
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(requests, hasLength(2));
      expect(jsonEncode(requests), contains('Private queued prompt'));
      expect(session.task!.pending, isEmpty);
      final sessionID = session.task!.id;
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
          final body = trace.singleWhere((event) => event['name'] == 'http.body' && event['ph'] == 'e');
          expect(body['args']['status'], 'ok', reason: 'Consuming a completed response is successful even before EOF');
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
    });
  }
}

class _LocalHttp extends HttpOverrides {}
