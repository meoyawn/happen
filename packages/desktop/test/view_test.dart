import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/conversation.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:desktop_drop/src/native_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  late _Client client;
  late DesktopSession session;
  Directory? directory;
  setUp(() {
    client = _Client();
    session = DesktopSession(client, _Database());
    session.providers = [
      {'id': 'gpt', 'name': 'ChatGPT', 'auth': 'chatgpt', 'status': 'signed_in', 'default_model': 'gpt-6.1-sol', 'models': [
        {'id': 'gpt-6.1-sol', 'default_reasoning': 'low', 'reasoning_levels': ['low'], 'reasoning_updates': true},
      ]},
      {'id': 'opencode', 'name': 'OpenCode', 'auth': 'opencode', 'status': 'signed_out', 'models': []},
    ];
    final task = DesktopTask('task', 'Example')
      ..loaded = true
      ..provider = 'gpt'
      ..model = 'gpt-6.1-sol'
      ..reasoning = 'low';
    session.projects.add(Project('checkout', '/project', '/project', [task]));
    session.project = session.projects.single;
    session.task = task;
  });
  tearDown(() async {
    await session.close();
    await directory?.delete(recursive: true);
    directory = null;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
  }

  testWidgets('expanded tool details survive switching away from the task and back', (tester) async {
    session.task!.events.addAll({
      1: {'seq': 1, 'type': 'tool.started', 'data': {'call_id': 'cell', 'namespace': 'functions', 'name': 'exec', 'input': 'text(await tools.exec_command({cmd: "pwd"}));'}},
      2: {'seq': 2, 'type': 'host_tool.started', 'data': {'id': 'shell', 'parent_call_id': 'cell', 'name': 'exec_command', 'arguments': {'cmd': 'pwd'}}},
      3: {'seq': 3, 'type': 'host_tool.completed', 'data': {'id': 'shell', 'output': {'output': '/project'}}},
    });
    await open(tester);
    await tester.tap(find.text('functions.exec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code & output'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('text(await tools.exec_command({cmd: "pwd"}));'), findsOneWidget);
    await tester.tap(find.text('exec_command'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('/project'), findsOneWidget);
    final task = session.task!;
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    await tester.runAsync(() => session.select(session.project!, task));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Enter sends and Shift Enter inserts a newline', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'First line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'First line\n');
    expect(client.sent, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['prompt'], 'First line\n');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('image paste retains the draft after rejection and sends with file attachments on retry', (tester) async {
    late File image, report;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('happen-paste-');
      final owned = await Directory('${directory!.path}/clipboard-image').create();
      image = await File('${owned.path}/Pasted image.png').writeAsBytes(base64Decode(_png));
      report = await File('${directory!.path}/report.txt').writeAsString('File contents');
    });
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('happen/clipboard');
    String? text;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => call.method == 'Clipboard.getData' && text != null ? {'text': text} : null);
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'read' ? {
      'text': text,
      'images': text == null ? [{'name': 'Pasted image.png', 'path': image.path}] : [],
      'files': text == null ? [report.path] : [],
    } : null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Inspect these');
    Future<void> paste() async {
      await tester.tap(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
    await paste();
    expect(find.byTooltip('Remove Pasted image.png'), findsOneWidget);
    expect(find.byTooltip('Remove report.txt'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Inspect these');
    client.rejectSend = true;
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fixture rejection'), findsOneWidget);
    expect(find.byTooltip('Remove Pasted image.png'), findsOneWidget);
    expect(session.drafts['task'], 'Inspect these');
    client.rejectSend = false;
    await tester.tap(find.byTooltip('Send message'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    client.events.add({'task_id': 'task', 'type': 'turn.completed', 'data': {}});
    await tester.pumpAndSettle();
    expect(client.sent.last['attachments'], [
      {'type': 'image', 'name': 'Pasted image.png', 'path': image.path},
      {'type': 'file', 'name': 'report.txt', 'path': report.path},
    ]);
    expect(find.byTooltip('Remove Pasted image.png'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.runAsync(() async {
      expect(await image.exists(), isFalse);
      expect(await report.readAsString(), 'File contents');
    });
    text = 'Ordinary paste';
    await paste();
    expect(session.error, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Ordinary paste');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('native drag and drop stages images and files before the source is released', (tester) async {
    late File image, report;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('happen-drop-');
      image = await File('${directory!.path}/drop.png').writeAsBytes(base64Decode(_png));
      report = await File('${directory!.path}/drop.txt').writeAsString('Dropped contents');
    });
    await open(tester);
    final point = tester.getCenter(find.byType(TextField));
    final event = <String, Object?>{
      'view': tester.view.viewId, 'generation': 0, 'session': 7, 'request': 1, 'phase': 1,
      'operation': 1, 'x': point.dx, 'y': point.dy,
      'offer': {'allowedOperations': ['copy'], 'isComplete': true, 'strings': [], 'files': [
        {'name': 'drop.png', 'path': image.path}, {'name': 'drop.txt', 'path': report.path},
      ]},
    };
    final native = NativeTransport.instance;
    final target = await native.onEvent!(MethodCall('query', event)) as Map;
    expect(target['target'], greaterThan(0));
    await tester.runAsync(() => native.onEvent!(MethodCall('drop', {...event, 'target': target['target']})));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove drop.png'), findsOneWidget);
    expect(find.byTooltip('Remove drop.txt'), findsOneWidget);
    await tester.runAsync(() => directory!.delete(recursive: true));
    directory = null;
    final attachments = session.attachmentDrafts['task']!;
    await tester.runAsync(() async {
      expect(await File(attachments.first.path).readAsBytes(), base64Decode(_png));
      expect(await File(attachments.last.path).readAsString(), 'Dropped contents');
    });
    await tester.tap(find.byTooltip('Remove drop.png'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove drop.png'), findsNothing);
    expect(find.byTooltip('Remove drop.txt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('reasoning can change while GPT is running and stays fixed for other tasks', (tester) async {
    (session.providers.first['models'] as List).first['reasoning_levels'] = ['low', 'high'];
    session.task!.reasoningUpdates = true;
    await open(tester);
    client.events.add({'task_id': 'task', 'type': 'turn.started', 'data': {}});
    await tester.pump();
    await tester.tap(find.text('low reasoning'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('high reasoning'), findsOneWidget);
    await tester.tap(find.text('high reasoning'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(session.reasoning, 'high');
    await tester.enterText(find.byType(TextField), 'Use more reasoning');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['reasoning'], 'high');
    expect(client.sent.single['delivery'], 'steer');

    session.task!.reasoningUpdates = false;
    client.events.add({'task_id': 'task', 'type': 'model.completed', 'data': {}});
    await tester.pump();
    final fixed = find.descendant(
      of: find.byTooltip('Reasoning is fixed for this task'),
      matching: find.byType(DropdownButton<String>),
    );
    expect(tester.widget<DropdownButton<String>>(fixed).onChanged, isNull);
    session.chooseReasoning('low');
    expect(session.reasoning, 'high');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('file mentions complete new and existing drafts without sending or damaging surrounding text', (tester) async {
    final existing = session.task!;
    session.task = null;
    await open(tester);
    final newDraftRect = tester.getRect(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Please @m');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'Please @ma');
    await tester.pump(const Duration(milliseconds: 199));
    expect(client.searches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(client.searches.single.cwd, '/project');
    expect(client.searches.single.query, 'ma');
    client.searches.single.reply.complete({'paths': ['lib/main.dart', 'notes/my file.md'], 'truncated': false});
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(TextField)), newDraftRect);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Please @"notes/my file.md" ');
    expect(session.drafts['checkout'], 'Please @"notes/my file.md" ');

    await tester.enterText(find.byType(TextField), 'Use @desktop');
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.searches.last.query, 'desktop');
    client.searches.last.reply.complete({'paths': ['packages/desktop/'], 'truncated': false});
    await tester.pumpAndSettle();
    expect(find.text('packages/desktop/'), findsOneWidget);
    expect(find.descendant(
      of: find.ancestor(of: find.text('packages/desktop/'), matching: find.byType(InkWell)),
      matching: find.byIcon(Icons.folder_outlined),
    ), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Use @packages/desktop/ ');
    expect(session.drafts['checkout'], 'Use @packages/desktop/ ');
    expect(client.sent, isEmpty);

    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Inspect @mainZZ afterwards');
    final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.searches.last.query, 'main');
    client.searches.last.reply.complete({'paths': ['lib/main.dart'], 'truncated': false});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(controller.text, 'Inspect @lib/main.dart afterwards');
    expect(controller.selection.baseOffset, 'Inspect @lib/main.dart '.length);
    expect(session.drafts[existing.id], controller.text);
    expect(client.sent, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['task_id'], existing.id);
    expect(client.sent.single['prompt'], 'Inspect @lib/main.dart afterwards');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('autocomplete never moves the composer, transcript viewport or reading position', (tester) async {
    for (var i = 1; i <= 30; i++) {
      session.task!.events[i] = {'seq': i, 'type': 'input.committed', 'data': {
        'item': {'role': 'user', 'content': [{'type': 'text', 'text': List.filled(8, 'Conversation message $i.').join('\n')}]},
      }};
    }
    await open(tester);
    final transcript = find.byType(ConversationTranscript);
    await tester.drag(transcript, const Offset(0, 240));
    await tester.pumpAndSettle();
    final scrolling = tester.state<ScrollableState>(find.descendant(
      of: transcript, matching: find.byType(Scrollable),
    ).first);
    final editorRect = tester.getRect(find.byType(TextField));
    final transcriptRect = tester.getRect(transcript);
    final readingPosition = scrolling.position.pixels;
    expect(readingPosition, greaterThan(0));
    void expectStable() {
      expect(tester.getRect(find.byType(TextField)), editorRect);
      expect(tester.getRect(transcript), transcriptRect);
      expect(scrolling.position.pixels, readingPosition);
      expect(tester.takeException(), isNull);
    }

    for (final count in [1, 20, 0]) {
      await tester.enterText(find.byType(TextField), '@query$count');
      await tester.pump(const Duration(milliseconds: 100));
      expectStable();
      await tester.pump(const Duration(milliseconds: 100));
      expectStable();
      client.searches.last.reply.complete({
        'paths': List.generate(count, (i) => i == 0 ? 'packages/desktop/' : 'lib/result$i.dart'),
        'truncated': count == 20,
      });
      await tester.pumpAndSettle();
      expectStable();
      if (count > 0) {
        expect(tester.getBottomLeft(find.text('packages/desktop/')).dy, lessThan(editorRect.top));
      }
    }
    await tester.enterText(find.byType(TextField), '@failure');
    await tester.pump(const Duration(milliseconds: 200));
    client.searches.last.reply.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('File search unavailable. Retry'), findsOneWidget);
    expectStable();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('File search unavailable. Retry'), findsNothing);
    expectStable();
    expect(client.sent, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('file suggestions reject late replies, dismiss, and leave email and IME input alone', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '@a');
    await tester.pump(const Duration(milliseconds: 200));
    final old = client.searches.single;
    await tester.enterText(find.byType(TextField), '@ab');
    await tester.pump(const Duration(milliseconds: 200));
    expect(old.cancellation.isCancelled, true);
    client.searches.last.reply.complete({'paths': ['current.dart'], 'truncated': false});
    await tester.pump();
    old.reply.complete({'paths': ['obsolete.dart'], 'truncated': false});
    await tester.pump();
    expect(find.text('current.dart'), findsOneWidget);
    expect(find.text('obsolete.dart'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('current.dart'), findsNothing);
    await tester.enterText(find.byType(TextField), 'email@example.com');
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.searches, hasLength(2));
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '@im', selection: TextSelection.collapsed(offset: 3), composing: TextRange(start: 0, end: 3),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.searches, hasLength(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, isEmpty);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '@im', selection: TextSelection.collapsed(offset: 3)));
    await tester.pump(const Duration(milliseconds: 200));
    final pending = client.searches.last;
    expect(pending.query, 'im');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, isEmpty, reason: 'Enter must not send while a suggestion is still loading');
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    expect(pending.cancellation.isCancelled, true);
    pending.reply.complete({'paths': ['old-task.dart'], 'truncated': false});
    await tester.pump();
    expect(find.text('old-task.dart'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('file search recovers from failure, accepts taps and cancels on disconnect', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '@"my f');
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.searches.single.query, 'my f');
    client.searches.single.reply.completeError(StateError('connection lost'));
    await tester.pump();
    await tester.tap(find.text('File search unavailable. Retry'));
    await tester.pump();
    client.searches.last.reply.complete({'paths': ['notes/my file.md'], 'truncated': false});
    await tester.pump();
    await tester.tap(find.text('notes/my file.md'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '@"notes/my file.md" ');
    expect(client.sent, isEmpty);
    await tester.enterText(find.byType(TextField), '@pending');
    await tester.pump(const Duration(milliseconds: 200));
    final pending = client.searches.last;
    await tester.runAsync(() => client.events.close());
    await tester.pump();
    expect(pending.cancellation.isCancelled, true);
    pending.reply.complete({'paths': ['disconnected.dart'], 'truncated': false});
    await tester.pump();
    expect(find.text('disconnected.dart'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Settings lists archived tasks, opens their history, and restores them', (tester) async {
    final archived = DesktopTask('archived', 'Old conversation')..archived = true..loaded = true;
    session.project!.tasks.add(archived);
    late Directory root;
    late IsolateOwner database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-settings-');
      directory = root;
      database = await openDesktopDatabase(root.path);
      await callIsolate(database.port, 'project.add', {'checkout_key': 'checkout', 'identity': '/project', 'path': '/project'});
      await callIsolate(database.port, 'task.add', {'id': archived.id, 'checkout_key': 'checkout', 'title': archived.title});
      await callIsolate(database.port, 'task.archive', {'task_id': archived.id, 'archived': true});
      final previous = session;
      await previous.close();
      client = _Client();
      session = DesktopSession(client, database)
        ..providers = previous.providers
        ..projects.addAll(previous.projects)
        ..project = previous.project
        ..task = previous.task;
    });
    await open(tester);
    expect(find.text('Old conversation'), findsNothing);
    expect(find.text('Archived'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Keep my draft');
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('On stop'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('On stop'));
      await callIsolate(database.port, 'load', {});
    });
    await tester.pumpAndSettle();
    expect(session.dictationMode, 'on_stop');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep my draft');
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Sign in to OpenCode'), findsOneWidget);
    expect(find.text('Steer'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    final row = find.byKey(const ValueKey('archived:archived'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(find.text('Archived tasks (1)'), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Old conversation')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('project')), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(session.task, same(archived));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Restore task to continue'), findsOneWidget);
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.descendant(of: row, matching: find.text('Restore')));
      await Future<void>.delayed(Duration.zero);
      await callIsolate(database.port, 'load', {});
    });
    await tester.pumpAndSettle();
    expect(client.restored, [archived.id]);
    expect(find.text('Archived tasks (0)'), findsOneWidget);
    expect(find.text('No archived tasks.'), findsOneWidget);
    expect(archived.archived, isFalse);
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}));
      expect((saved['tasks'] as List).single['archived'], 0);
    });
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.ancestor(of: find.text('Old conversation'), matching: find.byType(ListTile)),
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive task'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await callIsolate(database.port, 'load', {});
    });
    for (var attempt = 0; archived.archiving && attempt < 100; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Task archived'), findsOneWidget, reason: 'archived=${archived.archived}, archiving=${archived.archiving}, error=${session.error}');
    expect(find.text('Old conversation'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Task archived'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

class _Client implements AgentClient {
  @override bool get sharedFilesystem => true;
  @override final events = StreamController<Json>.broadcast();
  final sent = <Json>[];
  final restored = <String>[];
  final searches = <({String cwd, String query, CancellationToken cancellation, Completer<Json> reply})>[];
  bool rejectSend = false;
  @override Future<Json> searchFiles(String cwd, String query, {required CancellationToken cancellation}) {
    final reply = Completer<Json>();
    searches.add((cwd: cwd, query: query, cancellation: cancellation, reply: reply));
    return reply.future;
  }
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'task.unarchive' || method == 'task.archive') {
      if (method == 'task.unarchive') restored.add(params['task_id'] as String);
      return {'task_id': params['task_id'], 'archived': method == 'task.archive'};
    }
    if (method != 'task.send') throw StateError('Unexpected request: $method');
    sent.add(params);
    if (rejectSend) throw StateError('fixture rejection');
    return {'task_id': params['task_id']};
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

class _Database implements IsolateOwner {
  @override Future<void> close() async {}
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected database operation');
}
