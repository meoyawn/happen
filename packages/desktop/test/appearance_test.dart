import 'dart:async';
import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/appearance.dart';
import 'package:desktop/conversation.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('conversation view defaults safely and persists either selection across relaunch', () async {
    final root = await Directory.systemTemp.createTemp('desktop-appearance-');
    DesktopSession? session;
    addTearDown(() async {
      await session?.close();
      await root.delete(recursive: true);
    });
    Future<DesktopSession> launch() async {
      final next = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      session = next;
      await next.load();
      return next;
    }

    var current = await launch();
    expect(current.conversationStyle, ConversationStyle.harness);
    for (final style in [ConversationStyle.opencode, ConversationStyle.harness]) {
      await current.chooseConversationStyle(style);
      await current.close();
      session = null;
      current = await launch();
      expect(current.conversationStyle, style);
    }
    await callIsolate(current.database.port, 'settings.set', {'key': 'conversation_view', 'value': 'unknown-view'});
    await current.close();
    session = null;
    current = await launch();
    expect(current.conversationStyle, ConversationStyle.harness);
  });

  testWidgets('Settings switches the mounted conversation and composer while retaining draft, reading position and tool disclosure', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late DesktopSession session;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-appearance-view-');
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      await session.load();
    });
    addTearDown(() async {
      await session.close();
      await root.delete(recursive: true);
    });
    final task = _conversation();
    final project = Project('checkout', '/project', root.path, [task]);
    session.projects.add(project);
    session.project = project;
    session.task = task;
    await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this unfinished thought');
    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.selection = const TextSelection(baseOffset: 5, extentOffset: 9);
    await tester.tap(find.text('functions.exec'));
    await tester.pumpAndSettle();
    expect(find.text('Code & output'), findsOneWidget);
    final transcript = tester.state(find.byType(ConversationTranscript));
    final list = find.byKey(const PageStorageKey('transcript:appearance'));
    final scroll = tester.widget<ListView>(list).controller!;
    await tester.drag(list, const Offset(0, 120));
    await tester.pumpAndSettle();
    final position = scroll.offset;
    expect(position, greaterThan(0));
    final beforeSidebar = tester.getRect(find.byKey(const ValueKey('sidebar')));

    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    expect(find.text('Conversation view'), findsOneWidget);
    for (final style in [ConversationStyle.opencode, ConversationStyle.harness]) {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey('conversation-style:${style.name}')));
        await callIsolate(session.database.port, 'load', {});
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(session.conversationStyle, style);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ConversationTranscript)), same(transcript));
      expect(tester.widget<ListView>(list).controller, same(scroll));
      expect(scroll.offset, closeTo(position, 1));
      expect(tester.widget<TextField>(find.byType(TextField)).controller, same(editor));
      expect(editor.text, 'Keep this unfinished thought');
      expect(editor.selection, const TextSelection(baseOffset: 5, extentOffset: 9));
      expect(find.text('Code & output'), findsOneWidget);
      expect(tester.getRect(find.byKey(const ValueKey('sidebar'))), beforeSidebar);
      expect(ConversationAppearance.of(tester.element(find.byType(ConversationTranscript))), style);
      expect(session.task, same(task));
      expect(session.error, isNull);
      expect(tester.takeException(), isNull);
      if (style == ConversationStyle.opencode) {
        await tester.tap(find.byTooltip('App settings'));
        await tester.pumpAndSettle();
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final style in ConversationStyle.values) {
    testWidgets('${style.name} fits narrow conversations and keeps original response copying', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final task = _conversation();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: Scaffold(
        body: ConversationAppearance(style: style,
          child: ConversationTranscript(task: task, directory: '/project', onRetry: () {})),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Copy response').last);
      await tester.pump();
      expect(copied, _response);
      await tester.tap(find.text('functions.exec'));
      await tester.pumpAndSettle();
      expect(find.text('Code & output'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

const _response = '## A little more room to think\n\nYour changes are ready. The **conversation** keeps its history and tools.\n\n- Clear typography\n- Quiet surfaces\n- Room for the work';

DesktopTask _conversation() {
  final task = DesktopTask('appearance', 'Refine the workspace')..loaded = true;
  for (var index = 0; index < 8; index++) {
    task.events[index + 1] = {'seq': index + 1, 'type': 'input.committed', 'data': {'item': {
      'role': 'user', 'content': [{'type': 'text', 'text': 'Earlier message $index. Keep this conversation readable while we work.'}],
    }}};
  }
  task.events[9] = {'seq': 9, 'type': 'tool.started', 'data': {
    'call_id': 'code', 'namespace': 'functions', 'name': 'exec', 'input': 'text("ready")',
  }};
  task.events[10] = {'seq': 10, 'type': 'tool.completed', 'data': {'item': {'content': [
    {'call_id': 'code', 'output': 'ready'},
  ]}}};
  task.events[11] = {'seq': 11, 'type': 'model.completed', 'data': {'output': [
    {'content': [{'type': 'text', 'text': _response}]},
  ]}};
  return task;
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => true;
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'providers.list') return {'providers': []};
    throw StateError('Unexpected request: $method');
  }
  @override Future<Json> mcpInventory({bool verbose = false, String? server, required CancellationToken cancellation}) async => {'servers': []};
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
