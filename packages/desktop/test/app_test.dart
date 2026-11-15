import 'dart:async';
import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/composer_editor.dart';
import 'package:desktop/database.dart';
import 'package:desktop/project_avatar.dart';
import 'package:desktop/session.dart';
import 'package:desktop/terminal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('goal command changes the draft composer and controls the acknowledged goal', (tester) async {
    late Directory root;
    late DesktopSession session;
    final client = _GoalClient();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-goal-');
      session = DesktopSession(client, await openDesktopDatabase(root.path));
    });
    addTearDown(() => tester.runAsync(() async { await session.close(); await root.delete(recursive: true); }));
    final project = Project('checkout', 'project', root.path);
    session.projects.add(project);
    session.project = project;
    session.providers = [{'id': 'openai', 'status': 'signed_in', 'models': [
      {'id': 'example', 'reasoning_levels': <String>[]},
    ]}];
    session.chooseModel('example');
    tester.view.physicalSize = const Size(1100, 850); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), null));
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    ComposerEditor editor() => tester.widget<ComposerEditor>(find.byType(ComposerEditor));
    void type(String text) => editor().controller.value = TextEditingValue(text: text,
      selection: TextSelection.collapsed(offset: text.length));
    editor().focusNode.requestFocus();
    await tester.pump();
    type('/go');
    await tester.pump(const Duration(milliseconds: 250)); await tester.pump(); await tester.pump();
    expect(find.text('Set a goal to keep pursuing'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(editor().placeholder, contains('Describe your goal'));
    expect(editor().controller.text, isEmpty);
    expect(find.byTooltip('Exit goal mode'), findsOneWidget);
    final original = session.currentDraft;
    type('Ship the desktop goal workflow');
    session.newSession(project); await tester.pump();
    expect(editor().placeholder, isNot(contains('Describe your goal')));
    session.openDraft(original); await tester.pump();
    expect(editor().placeholder, contains('Describe your goal'));
    expect(editor().controller.text, 'Ship the desktop goal workflow');
    await tester.tap(find.byTooltip('Exit goal mode')); await tester.pump();
    expect(editor().controller.text, 'Ship the desktop goal workflow');
    type('/goal Ship the desktop goal workflow'); await tester.pump();
    expect(editor().controller.text, 'Ship the desktop goal workflow');
    expect(editor().placeholder, contains('Describe your goal'));

    client.goalReply = Completer<Json>();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Start goal'));
      for (var i = 0; i < 100 && !client.requests.any((call) => call.method == 'thread/goal/set'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    final target = session.task!;
    expect(find.textContaining('Saving goal…', findRichText: true), findsOneWidget);
    expect(target.goal, isNull, reason: 'A pending write is not a saved goal');
    expect(client.requests.where((call) => call.method == 'turn/start'), hasLength(1));
    expect(client.requests.firstWhere((call) => call.method == 'turn/start').params['input'], [
      {'type': 'text', 'text': 'Ship the desktop goal workflow'},
    ]);
    client.goalReply!.complete({'goal': client.goal});
    client.goalReply = null;
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 30)); });
    await tester.pump();
    expect(find.textContaining('Pursuing goal', findRichText: true), findsOneWidget);
    expect(find.byTooltip('Pause goal'), findsOneWidget);
    expect(find.byTooltip('Exit goal mode'), findsNothing);
    expect(editor().controller.text, isEmpty);

    client.goalReply = Completer<Json>();
    await tester.tap(find.byTooltip('Pause goal')); await tester.pump();
    expect(target.goal?['status'], 'active');
    client.events.add({'method': 'thread/goal/updated', 'params': {
      'threadId': target.id, 'goal': {...client.goal!, 'status': 'paused'},
    }});
    await tester.pump();
    // An older acknowledgement must not overwrite a newer notification.
    client.goalReply!.complete({'goal': {...client.goal!, 'status': 'active'}});
    client.goalReply = null;
    await tester.pump(); await tester.pump();
    expect(find.textContaining('Paused goal', findRichText: true), findsOneWidget);
    await tester.tap(find.byTooltip('Resume goal')); await tester.pump(); await tester.pump();
    expect(find.byTooltip('Pause goal'), findsOneWidget);
    expect(client.requests.where((call) => call.method == 'turn/start'), hasLength(1),
      reason: 'The backend owns continuation; goal controls do not send chat messages');

    client.failGoal = true;
    await tester.tap(find.byTooltip('Pause goal')); await tester.pump(); await tester.pump();
    expect(target.goal?['status'], 'active');
    expect(find.byTooltip('Retry saving goal'), findsOneWidget);
    client.failGoal = false;
    await tester.tap(find.byTooltip('Retry saving goal')); await tester.pump(); await tester.pump();
    expect(find.byTooltip('Resume goal'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit goal')); await tester.pump();
    expect(editor().controller.text, 'Ship the desktop goal workflow');
    await tester.tap(find.byTooltip('Exit goal mode')); await tester.pump();
    await tester.tap(find.byTooltip('Clear goal')); await tester.pump(); await tester.pump();
    expect(find.byKey(const ValueKey('goal-status')), findsNothing);
    expect(editor().controller.text, 'Ship the desktop goal workflow');
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => callIsolate(session.database.port, 'load', {}));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('holding Option and an arrow switches on each repeat and stops at the list boundary', (tester) async {
    late DesktopSession session;
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('thread-key-repeat-');
      session = DesktopSession(_Client(), await openDesktopDatabase(directory.path));
    });
    addTearDown(() => tester.runAsync(() async { await session.close(); await directory.delete(recursive: true); }));
    final tasks = [for (var index = 0; index < 4; index++)
      DesktopTask('thread-$index', 'Thread $index')..loaded = true..lastActivity = 4 - index];
    final project = Project('project', directory.path, directory.path, tasks);
    session.projects.add(project);
    session.project = project;
    session.task = tasks.first;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), null));
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.runAsync(() async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    expect(session.task, tasks[1]);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    expect(session.task, tasks[2]);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    expect(session.task, tasks[3]);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    expect(session.task, tasks[3]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    expect(session.task, tasks[1]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await callIsolate(session.database.port, 'load', {});
    });
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('new-session project menu preserves the draft while adding and switching projects', (tester) async {
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
    await _shortcut(tester, LogicalKeyboardKey.keyN);
    final secondDraftKey = session.draftKey;
    expect(secondDraftKey, isNot(draftKey));
    expect(tester.widget<ComposerEditor>(find.byType(ComposerEditor)).controller.text, isEmpty);
    for (final (key, shift) in [
      (LogicalKeyboardKey.keyN, false),
      (LogicalKeyboardKey.keyN, true),
      (LogicalKeyboardKey.keyO, true),
    ]) {
      await _shortcut(tester, key, shift: shift);
      expect(session.draftKey, secondDraftKey);
      expect(session.sessionDrafts, hasLength(2));
    }
    await _shortcut(tester, LogicalKeyboardKey.bracketLeft, shift: true);
    expect(session.draftKey, draftKey);
    expect(tester.widget<ComposerEditor>(find.byType(ComposerEditor)).controller.text, 'Keep editing across projects');
    await _shortcut(tester, LogicalKeyboardKey.digit2);
    expect(session.draftKey, draftKey, reason: 'Empty drafts do not occupy a sidebar shortcut');
    await _shortcut(tester, LogicalKeyboardKey.bracketLeft);
    expect(session.draftKey, secondDraftKey);
    await _shortcut(tester, LogicalKeyboardKey.bracketRight);
    expect(session.draftKey, draftKey);
    await _shortcut(tester, LogicalKeyboardKey.keyN);
    expect(session.draftKey, secondDraftKey);
    expect(find.text('New session'), findsNothing);
    await _shortcut(tester, LogicalKeyboardKey.keyB);
    expect(session.sidebarOpen, isFalse);
    await _shortcut(tester, LogicalKeyboardKey.keyB);
    expect(session.sidebarOpen, isTrue);
    await _shortcut(tester, LogicalKeyboardKey.keyB);
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

  testWidgets('T3 Code panel, picker and terminal shortcuts follow focus', (tester) async {
    late Directory root;
    late DesktopSession session;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-shortcuts-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      addTearDown(() => tester.runAsync(session.close));
    });
    final task = DesktopTask('task', 'Shortcut focus')
      ..loaded = true..provider = 'openai'..model = 'example'
      ..reasoning = 'low'..reasoningUpdates = true;
    final project = Project('checkout', 'project', root.path, [task]);
    session.projects.add(project);
    session.project = project;
    session.task = task;
    session.providers = [
      {'id': 'openai', 'name': 'ChatGPT', 'auth': 'chatgpt', 'status': 'signed_in', 'models': [
        {'id': 'example', 'default_reasoning': 'low', 'reasoning_levels': ['low', 'high']},
      ]},
    ];
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), null));
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();

    await _shortcut(tester, LogicalKeyboardKey.keyM, shift: true);
    expect(find.text('Start a new task to change models.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _shortcut(tester, LogicalKeyboardKey.keyE, shift: true);
    expect(find.text('High'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await _shortcut(tester, LogicalKeyboardKey.keyB, alt: true);
    final panels = session.panelsFor(task);
    expect(panels.opened, isTrue);
    expect(panels.tabs, hasLength(1));
    await _shortcut(tester, LogicalKeyboardKey.keyT);
    expect(panels.tabs, hasLength(2));
    await _shortcut(tester, LogicalKeyboardKey.keyW);
    expect(panels.tabs, hasLength(1));
    await _shortcut(tester, LogicalKeyboardKey.keyW);
    expect(panels.opened, isFalse);
    await _shortcut(tester, LogicalKeyboardKey.keyW);
    expect(session.task, same(task), reason: 'Closing an empty panel must keep the thread open');

    await _shortcut(tester, LogicalKeyboardKey.keyJ);
    final group = session.terminals.groups[(project.checkoutKey, task.id)]!;
    expect(group.visible, isTrue);
    expect(group.sessions, hasLength(1));
    expect(terminalHasFocus, isTrue);
    await _shortcut(tester, LogicalKeyboardKey.keyN);
    expect(group.sessions, hasLength(2));
    expect(session.sessionDrafts, isEmpty, reason: 'New in a terminal creates a shell');
    await _shortcut(tester, LogicalKeyboardKey.keyK);
    expect(find.byType(Dialog), findsNothing, reason: 'The terminal keeps its command-palette chord');
    await _shortcut(tester, LogicalKeyboardKey.keyW);
    expect(group.sessions, hasLength(1));
    await _shortcut(tester, LogicalKeyboardKey.keyJ);
    expect(group.visible, isFalse);
    await _shortcut(tester, LogicalKeyboardKey.keyJ);
    expect(group.sessions, hasLength(1), reason: 'Showing the terminal reuses its shell');
    await _shortcut(tester, LogicalKeyboardKey.keyW);
    expect(group.visible, isFalse);
    expect(session.task, same(task));
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => callIsolate(session.database.port, 'load', {}));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}));

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

Future<void> _shortcut(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false, bool alt = false}) async {
  final primary = defaultTargetPlatform == TargetPlatform.macOS
    ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(primary);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.runAsync(() => tester.sendKeyEvent(key));
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(primary);
  await tester.pumpAndSettle();
}

// This test owns rendering of incoming events. Real WebSocket ownership is
// exercised by lifecycle_test; keeping I/O out of Flutter's fake clock also
// lets conversation inventory and teardown complete independently.
class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => true;
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'thread/list') return {'data': <Object?>[], 'nextCursor': null};
    throw StateError('Unexpected request: $method');
  }
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async =>
    jsonObject(await request(method, params));
  @override Future<Json> mcpInventory({bool verbose = false, String? server, String? cwd, required CancellationToken cancellation}) async => {'servers': <Object?>[]};
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GoalClient extends _Client {
  final requests = <({String method, Json params})>[];
  Json? goal;
  Completer<Json>? goalReply;
  bool failGoal = false;
  @override
  Future<Object?> request(String method, [Json params = const {}]) async {
    requests.add((method: method, params: params));
    switch (method) {
      case 'thread/start': return {'thread': {'id': 'goal-thread'}, 'configuration': <String, Object?>{}};
      case 'turn/start': return <String, Object?>{};
      case 'thread/goal/set':
        if (failGoal) throw StateError('Goal store unavailable');
        goal = {...?goal, 'threadId': params['threadId'],
          if (params['objective'] != null) 'objective': params['objective'], 'status': params['status'],
          'tokensUsed': 0, 'timeUsedSeconds': 0, 'updatedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000};
        return goalReply?.future ?? Future.value({'goal': goal});
      case 'thread/goal/clear': goal = null; return <String, Object?>{};
      default: return super.request(method, params);
    }
  }
  @override
  Future<Json> searchSkills(String cwd, String query, {String? provider, required CancellationToken cancellation}) async =>
    {'skills': <Json>[], 'truncated': false};
  @override
  Future<Json> gitRequest(String method, Json params, {required CancellationToken cancellation}) async =>
    {'isRepo': false, 'files': <Object?>[]};
}
