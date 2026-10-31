import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:desktop/lifecycle.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server/server.dart';

void main() {
  final binding = _LifecycleTestBinding();
  setUp(binding.exits.clear);
    testWidgets('two distinct quit presses await shutdown', (tester) async {
      final platform = defaultTargetPlatform;
      final closed = Completer<void>();
      var closes = 0;
      final editor = TextEditingController(text: 'Keep this draft');
      addTearDown(editor.dispose);
      await tester.pumpWidget(MaterialApp(home: DesktopLifecycle(
        onQuit: () { closes++; return closed.future; },
        child: Scaffold(body: TextField(controller: editor, autofocus: true)),
      )));
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus;
      final modifier = platform == TargetPlatform.macOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(find.textContaining('again to quit'), findsOneWidget);
      expect(closes, 0);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(closes, 0);
      expect(binding.exits, isEmpty);
      expect(editor.text, 'Keep this draft');
      expect(FocusManager.instance.primaryFocus, same(focus));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(modifier);
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(closes, 1);
      expect(binding.exits, isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(modifier);
      closed.complete();
      await tester.pump();
      expect(binding.exits, [AppExitType.required]);
      expect(find.textContaining('again to quit'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows}));

  testWidgets('quit confirmation expires and cancels on Escape, other input, click, or blur', (tester) async {
    var closes = 0;
    await tester.pumpWidget(MaterialApp(home: DesktopLifecycle(
      onQuit: () async { closes++; },
      child: const Scaffold(body: TextField(autofocus: true)),
    )));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    Future<void> arm() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(find.textContaining('again to quit'), findsOneWidget);
    }
    Future<void> expectDismissed() async {
      await tester.pump();
      expect(find.textContaining('again to quit'), findsNothing);
      expect(closes, 0);
    }
    await arm();
    await tester.pump(const Duration(seconds: 3));
    await expectDismissed();
    await arm();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await expectDismissed();
    await arm();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await expectDismissed();
    await arm();
    await tester.tapAt(const Offset(10, 10));
    await expectDismissed();
    await arm();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await expectDismissed();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await arm();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
    expect(closes, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('hidden desktop keeps its embedded server connected until tray Quit', (tester) async {
    late Directory root;
    late AgentServer server;
    late AgentClient client;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-lifecycle-');
      addTearDown(() => root.delete(recursive: true));
      final config = File('${root.path}/config.yaml');
      await config.writeAsString('{}');
      server = await AgentServer.startEmbedded(directory: root.path, configPath: config.path);
      addTearDown(server.close);
      client = await HttpOverrides.runWithHttpOverrides(
        () => AgentClient.connect(server.uri, token: server.token), _LocalHttpOverrides());
      addTearDown(client.close);
    });
    var closes = 0;
    await tester.pumpWidget(MaterialApp(home: DesktopLifecycle(
      onQuit: () async {
        closes++;
        await client.close();
        await server.close();
      },
      child: const Scaffold(body: Text('Running')),
    )));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    await tester.runAsync(() async {
      expect(await client.request('providers.list'), isA<Map>());
    });
    expect(closes, 0);
    expect(binding.exits, isEmpty);
    expect(find.textContaining('again to quit'), findsNothing);
    await tester.runAsync(() async {
      final response = await tester.binding.defaultBinaryMessenger.handlePlatformMessage('happen/lifecycle',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('quit')), (_) {});
      const StandardMethodCodec().decodeEnvelope(response!);
    });
    expect(closes, 1);
    expect(client.events.isClosed, isTrue);
    if (server.socketPath case final path?) {
      expect(await tester.runAsync(() => File(path).exists()), isFalse);
    }
    expect(binding.exits, [AppExitType.required]);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}

class _LocalHttpOverrides extends HttpOverrides {}

// Substitute only the process exit; Flutter's standard test binding rejects it.
class _LifecycleTestBinding extends AutomatedTestWidgetsFlutterBinding {
  final exits = <AppExitType>[];

  @override
  Future<AppExitResponse> exitApplication(AppExitType type, [int exitCode = 0]) async {
    exits.add(type);
    return AppExitResponse.exit;
  }
}
