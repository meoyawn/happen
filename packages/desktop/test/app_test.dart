import 'dart:async';
import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/composer_editor.dart';
import 'package:desktop/database.dart';
import 'package:desktop/project_avatar.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('new-session project menu preserves the tab draft while adding and switching projects', (tester) async {
    late Directory root, firstFolder, secondFolder;
    late DesktopSession session;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-new-session-');
      root = Directory(await root.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      firstFolder = await Directory('${root.path}/first').create();
      secondFolder = await Directory('${root.path}/second').create();
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      addTearDown(() => tester.runAsync(session.close));
      await session.addProject(firstFolder.path);
    });
    final first = session.project!;
    final draftKey = session.draftKey;
    session.drafts[draftKey] = 'Keep this tab draft';
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? pickedPath;
    final pickerCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('macos_file_picker'), (call) async {
      pickerCalls.add(call);
      return pickedPath == null ? null : [
        {'url': Uri.directory(pickedPath).toString(), 'path': pickedPath, 'name': 'second'},
      ];
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('macos_file_picker'), null));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), null));

    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    final editor = tester.widget<ComposerEditor>(find.byType(ComposerEditor));
    editor.controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.tap(find.byTooltip('Select project'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('project-search')), findsOneWidget);
    expect(find.byType(ProjectAvatar), findsWidgets);
    expect(find.text('Add project'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('Add project')));
    await tester.pumpAndSettle();
    expect(pickerCalls, hasLength(1));
    expect(session.project, same(first), reason: 'Cancelling the folder picker keeps the current draft');
    expect(editor.controller.text, 'Keep this tab draft');
    expect(editor.controller.selection, const TextSelection.collapsed(offset: 5));

    pickedPath = secondFolder.path;
    await tester.tap(find.byTooltip('Select project'));
    await tester.pumpAndSettle();
    // Folder discovery runs real Git processes and talks to the database isolate.
    await tester.runAsync(() async {
      final added = Completer<void>();
      void changed() {
        if (session.projects.length == 2 && !added.isCompleted) added.complete();
      }
      session.addListener(changed);
      try {
        await tester.tap(find.text('Add project'));
        await added.future.timeout(const Duration(seconds: 10));
      } finally {
        session.removeListener(changed);
      }
    });
    await tester.pumpAndSettle();
    expect(session.projects, hasLength(2));
    expect(session.task, isNull);
    expect(session.project, isNot(same(first)));
    expect(session.draftKey, draftKey);
    expect(tester.widget<ComposerEditor>(find.byType(ComposerEditor)).controller, same(editor.controller));
    expect(editor.controller.text, 'Keep this tab draft');
    editor.controller.text = 'Keep editing across projects';
    await tester.pump();

    await tester.tap(find.byTooltip('Select project'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('project-search')), 'unmatched');
    await tester.pump();
    expect(find.text('No projects found.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('project-search')), 'first');
    await tester.pump();
    await tester.runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.enter));
    await tester.pumpAndSettle();
    expect(session.project, same(first));
    expect(find.byKey(const ValueKey('project-search')), findsNothing);
    expect(tester.widget<ComposerEditor>(find.byType(ComposerEditor)).controller.text, 'Keep editing across projects');
    expect(session.drafts[draftKey], 'Keep editing across projects');
    session.newSession();
    final secondDraftKey = session.draftKey;
    await tester.pumpAndSettle();
    expect(tester.widget<ComposerEditor>(find.byType(ComposerEditor)).controller.text, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(session.draftKey, draftKey);
    expect(tester.widget<ComposerEditor>(find.byType(ComposerEditor)).controller.text, 'Keep editing across projects');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(session.draftKey, secondDraftKey);
    tester.view.physicalSize = const Size(420, 600);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select project'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-search')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-search')), findsNothing);
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => callIsolate(session.database.port, 'load', {}));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('tool details remain readable through updates and expansion', (tester) async {
    late Directory root;
    late DesktopSession session;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-view-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(
        _Client(),
        await openDesktopDatabase(root.path),
      );
      addTearDown(() => tester.runAsync(session.close));
    });
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final task = DesktopTask('task', 'Inspect runtime tools')..running = true;
    session.projects.add(Project('checkout', 'project', root.path, [task]));
    session.project = session.projects.single;
    session.task = task;
    var sequence = 0;
    Future<void> emit(String type, Json data) async {
      session.client.events.add({
        'task_id': task.id,
        'seq': ++sequence,
        'type': type,
        'data': data,
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.macOS),
      home: DesktopView(session: session),
    ));
    await emit('tool.started', {
      'call_id': 'cell',
      'namespace': 'functions',
      'name': 'exec',
      'input': 'text(await tools.runtime_status({}));',
    });
    expect(find.text('Code & output'), findsNothing);
    await tester.tap(find.text('functions.exec'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Code & output'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('text(await tools.runtime_status({}));'), findsOneWidget);
    final source = tester.widget<SelectableText>(find.byType(SelectableText).first);
    expect(source.textSpan, isNotNull);
    final tokens = <TextSpan>[];
    source.textSpan!.visitChildren((span) {
      if (span is TextSpan) tokens.add(span);
      return true;
    });
    expect(tokens.where((span) => span.text == 'await').single.style?.color, isNotNull);
    expect(tokens.where((span) => span.text == 'text').single.style?.color, isNotNull);

    await emit('host_tool.started', {
      'id': 'host',
      'parent_call_id': 'cell',
      'name': 'runtime_status',
      'arguments': <String, Object?>{},
    });
    await emit('host_tool.completed', {'id': 'host', 'output': 'One active app'});
    await emit('tool.completed', {
      'item': {
        'content': [
          {'call_id': 'cell', 'output': 'One active app'},
        ],
      },
    });
    await emit('turn.completed', {});
    await tester.pumpAndSettle();
    const details = 'text(await tools.runtime_status({}));\n\nOne active app';
    expect(find.text(details), findsOneWidget);
    final completed = tester.widget<SelectableText>(find.byType(SelectableText).first);
    expect(completed.textSpan!.toPlainText(), details);
    final output = <TextSpan>[];
    completed.textSpan!.visitChildren((span) {
      if (span is TextSpan && span.text == '\n\nOne active app') output.add(span);
      return true;
    });
    expect(output.single.style?.color, isNull);

    await tester.tap(find.text('Code & output'));
    await tester.pumpAndSettle();
    expect(find.text(details), findsNothing);
    await tester.tap(find.text('functions.exec'));
    await tester.pumpAndSettle();
    expect(find.text('Code & output'), findsNothing);
    await tester.tap(find.text('functions.exec'));
    await tester.pumpAndSettle();
    expect(find.text('Code & output'), findsOneWidget);
    expect(find.text(details), findsNothing);
    await tester.tap(find.text('Code & output'));
    await tester.pumpAndSettle();
    expect(find.text(details), findsOneWidget);
    await tester.tap(find.text('runtime_status'));
    await tester.pumpAndSettle();
    expect(find.text('{}\n\nOne active app'), findsOneWidget);

    await emit('turn.started', {});
    session.client.events.add({'task_id': task.id, 'type': 'text.delta', 'delta': 'Abandoned partial answer'});
    await tester.pump();
    session.client.events.add({'task_id': task.id, 'type': 'model.retrying', 'attempt': 1, 'max_retries': 5});
    await tester.pump();
    expect(find.textContaining('Reconnecting… 1/5'), findsOneWidget);
    expect(find.text('Abandoned partial answer', findRichText: true), findsNothing);
    session.client.events.add({'task_id': task.id, 'type': 'model.connected'});
    await tester.pump();
    expect(find.textContaining('Reconnecting…'), findsNothing);
    expect(find.textContaining('Working'), findsOneWidget);
    session.client.events.add({'task_id': task.id, 'type': 'text.delta', 'delta': 'Recovered answer'});
    await tester.pump();
    expect(find.textContaining('Reconnecting…'), findsNothing);
    expect(find.text('Recovered answer', findRichText: true), findsOneWidget);
    await emit('compaction.started', {'reason': 'overflow'});
    expect(session.task!.streamingText, isEmpty);
    expect(find.textContaining('Compacting context'), findsOneWidget);
    expect(find.textContaining('Working'), findsNothing);
    // Older servers can still send compaction deltas. Keep them out of prose.
    session.client.events.add({'task_id': task.id, 'type': 'text.delta', 'delta': 'Internal summary'});
    session.client.events.add({'task_id': task.id, 'type': 'model.retrying', 'attempt': 1, 'max_retries': 5});
    await tester.pump();
    expect(find.textContaining('Compacting context · Reconnecting… 1/5'), findsOneWidget);
    expect(find.text('Internal summary', findRichText: true), findsNothing);
    session.client.events.add({'task_id': task.id, 'type': 'model.connected'});
    await tester.pump();
    expect(find.textContaining('Reconnecting…'), findsNothing);
    expect(find.textContaining('Compacting context'), findsOneWidget);
    await emit('context.compacted', {'summary': ''});
    expect(session.task!.streamingText, isEmpty);
    expect(session.task!.retryStatus, isNull);
    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.textContaining('Working'), findsOneWidget);
    await emit('turn.completed', {});
    await tester.pumpAndSettle();

    // Failures before a durable sequence is available must remain in the
    // conversation, including after rebuilding the transcript.
    session.client.events.add({
      'task_id': task.id,
      'type': 'turn.failed',
      'data': {'error': 'Worker exited before replying'},
    });
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Worker exited before replying'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong'), findsOneWidget);
    await emit('turn.started', {});
    await emit('turn.completed', {});
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

// This test owns rendering of incoming events. Real WebSocket ownership is
// exercised by lifecycle_test; keeping I/O out of Flutter's fake clock also
// lets conversation inventory and teardown complete independently.
class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'session.active') return {'data': <String, Object?>{}};
    if (method == 'session.list') return {'data': <Object?>[], 'cursor': <String, Object?>{}};
    throw StateError('Unexpected request: $method');
  }
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async =>
    jsonObject(await request(method, params));
  @override Future<Json> mcpInventory({bool verbose = false, String? server, required CancellationToken cancellation}) async => {'servers': <Object?>[]};
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
