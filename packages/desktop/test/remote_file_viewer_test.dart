import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:desktop/session_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:re_editor/re_editor.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('file panels read and reload paths that exist only on the selected server', (tester) async {
    const path = '/__happen_remote_only__/mise.toml';
    var contents = '[tools]\ngo = "1.24"\n';
    late Directory root;
    late HttpServer http;
    late DesktopSession session;
    final peers = <WebSocket>[], subscriptions = <StreamSubscription<dynamic>>[];
    await tester.runAsync(() async {
      expect(await File(path).exists(), false);
      root = await Directory.systemTemp.createTemp('remote-file-viewer-');
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      subscriptions.add(http.transform(WebSocketTransformer()).listen((socket) {
        peers.add(socket);
        subscriptions.add(socket.listen((raw) {
          final request = jsonObject(jsonDecode(raw as String));
          if (request['id'] == null) return;
          final result = switch (request['method']) {
            'initialize' => <String, Object?>{'userAgent': 'filesystem-fixture'},
            'fs/getMetadata' when request['params']['path'] == path => <String, Object?>{
              'isFile': true, 'isDirectory': false, 'isSymlink': false,
              'createdAtMs': 0, 'modifiedAtMs': 0, 'size': utf8.encode(contents).length,
            },
            'fs/readFile' when request['params']['path'] == path => <String, Object?>{
              'dataBase64': base64Encode(utf8.encode(contents)),
            },
            _ => throw StateError('Unexpected filesystem request: ${request['method']}'),
          };
          socket.add(jsonEncode({'id': request['id'], 'result': result}));
        }));
      }));
      final client = await HttpOverrides.runWithHttpOverrides(
        () => AgentClient.connect(Uri.parse('ws://127.0.0.1:${http.port}/ws')), _LocalHttp());
      session = DesktopSession(client, await openDesktopDatabase(root.path));
      await session.loadPanelLayouts(CancellationToken());
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await session.close();
        for (final peer in peers) { await peer.close(); }
        for (final subscription in subscriptions) { await subscription.cancel(); }
        await http.close(force: true);
        await root.delete(recursive: true);
      });
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = DesktopTask('remote-thread', 'Remote file')..loaded = true;
    final project = Project('remote', 'Remote', '/__happen_remote_only__', [task]);
    session.projects.add(project);
    session.project = project;
    session.task = task;
    session.openSessionPanel(task, 'file:$path', line: 2);
    await tester.pumpWidget(MaterialApp(home: SessionPanelWorkspace(
      session: session, task: task, onReturnFocus: () {},
      sideComposer: (_, _) => const SizedBox.shrink(), child: const SizedBox.shrink())));

    Future<void> loaded(String expected) async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        final editors = tester.widgetList<CodeEditor>(find.byType(CodeEditor));
        if (editors.isNotEmpty && editors.single.controller?.text == expected) return;
      }
      fail('The remote file contents were not rendered.');
    }
    await loaded('[tools]\ngo = "1.24"\n');
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.controller!.selection.baseIndex, 1);
    expect(find.byTooltip('Reveal in Finder'), findsNothing);
    expect(find.byTooltip('Reveal in File Manager'), findsNothing);
    contents = '[tools]\ngo = "1.25"\n';
    await tester.tap(find.byTooltip('Reload file'));
    await loaded('[tools]\ngo = "1.25"\n');
    expect(tester.takeException(), isNull);
  });
}

class _LocalHttp extends HttpOverrides {}
