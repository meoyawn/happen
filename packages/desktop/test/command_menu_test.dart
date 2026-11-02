import 'dart:async';
import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/appearance.dart';
import 'package:desktop/command_menu.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:desktop/settings_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('command menu opens full-height archive previews without suggesting archived chats', (tester) async {
    late DesktopSession session;
    late Directory root;
    final client = _Client();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-command-menu-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(client, await openDesktopDatabase(root.path));
      addTearDown(() => tester.runAsync(session.close));
    });
    final archived = [
      for (var i = 0; i < 20; i++)
        DesktopTask('archived-$i', 'Archived-only conversation $i')..archived = true,
    ];
    final project = Project('project', 'project', root.path, [
      DesktopTask('active', 'Active conversation'), ...archived,
    ]);
    session.projects.add(project);
    session.project = project;
    session.viewingConversation = false;
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('happen/desktop'), null));

    await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    final modifier = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    Future<void> toggleMenu() async {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
    }

    await toggleMenu();
    expect(find.byType(CommandMenu), findsOneWidget);
    expect(find.text('Archived sessions'), findsOneWidget);
    expect(find.text('Archived-only conversation 0'), findsNothing);
    final search = find.byKey(const ValueKey('command-menu-search'));
    await tester.enterText(search, 'Archived-only');
    await tester.pumpAndSettle();
    expect(find.text('No results'), findsOneWidget);
    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(CommandMenu), findsNothing);
    expect(find.text('Archived tasks (20)'), findsOneWidget);
    final lowerRow = find.byKey(const ValueKey('archived:archived-6'));
    expect(lowerRow.hitTestable(), findsOneWidget,
      reason: 'The archive uses the available page height instead of a small nested viewport');
    expect(tester.getBottomLeft(lowerRow).dy, greaterThan(500));

    final last = archived.last;
    final lastRow = find.byKey(ValueKey('archived:${last.id}'));
    await tester.scrollUntilVisible(lastRow, 400,
      scrollable: find.descendant(of: find.byKey(const PageStorageKey('archived-sessions')),
        matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    await tester.tap(lastRow);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('archived-preview')), findsOneWidget);
    expect(find.text('Read-only archived preview'), findsOneWidget);
    expect(session.task, isNull);
    expect(session.viewingConversation, isFalse);
    expect(tester.getSize(find.byKey(ValueKey('archived-transcript:${last.id}'))).height, greaterThan(600));
    await tester.tap(find.text('Back to archived tasks'));
    await tester.pumpAndSettle();
    expect(lastRow.hitTestable(), findsOneWidget);
    await tester.tap(lastRow);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final restored = Completer<void>();
      void changed() {
        if (!last.archived && !last.archiving && !restored.isCompleted) restored.complete();
      }
      session.addListener(changed);
      try {
        await tester.tap(find.text('Restore'));
        await restored.future.timeout(const Duration(seconds: 10));
      } finally {
        session.removeListener(changed);
      }
    });
    await tester.pumpAndSettle();
    expect(client.restored, [last.id]);
    expect(session.task, isNull);
    expect(session.viewingConversation, isFalse);
    expect(find.byType(DesktopSettingsScreen), findsOneWidget);
    expect(find.text('Archived tasks (19)'), findsOneWidget);
    expect(lastRow, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await toggleMenu();
    expect(find.descendant(of: find.byType(CommandMenu), matching: find.text(last.title)), findsOneWidget);
    await toggleMenu();
    expect(find.byType(CommandMenu), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows}));
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  final restored = <String>[];
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async {
    if (method == 'session.message.list') return {
      'through': 1, 'archived': true,
      'data': [{
        'id': 'message', 'type': 'user', 'metadata': {'seq': 1}, 'time': {'created': 1},
        'text': 'Read-only archived preview',
      }],
    };
    throw StateError('Unexpected read: $method');
  }
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'session.unarchive') {
      restored.add(params['sessionID'] as String);
      return null;
    }
    throw StateError('Unexpected request: $method');
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
