import 'dart:async';
import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('remote terminal opens from the toolbar, keeps its shell when hidden, and accepts emulator input', (tester) async {
    late Directory root;
    late AgentServer server;
    late DesktopSession session;
    var closed = false;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('remote-terminal-ui-');
      server = await AgentServer.start(directory: '${root.path}/server', port: 0,
        configPath: '${root.path}/config.yaml', skillsHome: root.path, telemetry: false);
      session = DesktopSession(await HttpOverrides.runWithHttpOverrides(
        () => AgentClient.connect(server.uri, sharedFilesystem: false), _LocalHttp()),
        await openDesktopDatabase('${root.path}/desktop'));
    });
    addTearDown(() async {
      if (closed) return;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await session.close(); await server.close(); await root.delete(recursive: true);
      });
    });
    tester.view.physicalSize = const Size(1200, 900); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), null));
    final project = Project('host-checkout', 'Remote checkout', root.path, []);
    session.projects.add(project); session.project = project;
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pump(const Duration(milliseconds: 300));
    final toggle = find.byTooltip(RegExp(r'^Toggle terminal'));
    await tester.runAsync(() async {
      await tester.tap(toggle);
      // The macOS title bar waits for a possible double click.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(session.connected, true);
      expect(session.terminals.groups, hasLength(1));
      final shell = session.terminals.groups[(project.checkoutKey, session.draftKey)]!.active!;
      final ready = Completer<void>();
      void changed() {
        if (shell.error != null && !ready.isCompleted) ready.completeError(StateError(shell.error!));
        if (shell.running && !ready.isCompleted) ready.complete();
      }
      shell.addListener(changed); changed();
      try { await ready.future.timeout(const Duration(seconds: 10)); }
      finally { shell.removeListener(changed); }
    });
    await tester.pump();
    final scope = (project.checkoutKey, session.draftKey);
    final shell = session.terminals.groups[scope]!.active!;
    expect(shell.running, true);
    await tester.tap(find.byTooltip('Hide terminal'));
    await tester.pump();
    expect(session.terminals.groups[scope]!.visible, false);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 350));
    expect(session.terminals.groups[scope]!.visible, true);
    expect(session.terminals.groups[scope]!.active, same(shell));
    expect(session.terminals.groups[scope]!.sessions, hasLength(1));
    await tester.runAsync(() async {
      shell.terminal.textInput("printf 'remote ui input' > terminal.marker\r");
      final deadline = Stopwatch()..start();
      final marker = File('${root.path}/terminal.marker');
      while (!await marker.exists()) {
        if (deadline.elapsed > const Duration(seconds: 10)) throw StateError('Emulator input did not reach the host shell');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await marker.readAsString(), 'remote ui input');
    });
    await tester.runAsync(() async { await session.terminals.removeProject(project.checkoutKey); });
    await tester.pump();
    expect(shell.running, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await session.close(); await server.close(); await root.delete(recursive: true);
      closed = true;
    });
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}));
}

class _LocalHttp extends HttpOverrides {}
