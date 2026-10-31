import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:desktop/app.dart';
import 'package:desktop/composer_text_controller.dart';
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
    client.providers = session.providers;
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

  testWidgets('context circle uses the latest response and retains cache hits across replay and live events', (tester) async {
    final task = session.task!;
    task.events.addAll({
      3: {'seq': 3, 'type': 'model.completed', 'data': {'usage': {'input_tokens': 39000, 'output_tokens': 1000, 'cached_input_tokens': 30000}}},
      1: {'seq': 1, 'type': 'task.created', 'data': {'provider_settings': {'context_limit': 100000}}},
      2: {'seq': 2, 'type': 'model.completed', 'data': {'usage': {'input_tokens': 10000, 'output_tokens': 1000, 'cached_input_tokens': 0}}},
    });
    await open(tester);
    final circle = find.bySemanticsLabel(RegExp(r'^Context usage:'));
    final contextTooltip = find.byWidgetPredicate((widget) => widget is Tooltip && widget.richMessage?.toPlainText().startsWith('Context window:') == true);
    expect(find.bySemanticsLabel('Context usage: 40%'), findsOneWidget);
    expect(tester.getSize(contextTooltip), const Size.square(28));
    final modelPicker = find.byTooltip('Model and reasoning effort');
    expect(tester.getCenter(circle).dx, greaterThan(tester.getCenter(find.byType(TextField)).dx));
    expect(tester.getCenter(circle).dx, lessThan(tester.getRect(modelPicker).left));
    expect(tester.getRect(modelPicker).right, lessThan(tester.getCenter(find.byTooltip('Dictate')).dx));
    expect(find.text('Enter to send · Shift+Enter for a new line'), findsNothing);
    expect(find.text('40%'), findsNothing, reason: 'Usage text belongs in the tooltip');
    await tester.enterText(find.byType(TextField), 'Keep my draft');
    final editor = tester.widget<TextField>(find.byType(TextField));
    final selection = editor.controller!.selection;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    Future<void> hover() async {
      final target = tester.getRect(contextTooltip);
      await mouse.moveTo(Offset(target.left + 2, target.center.dy));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }
    Future<void> leave() async {
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }
    await hover();
    expect(find.textContaining('40% used (60% left)', findRichText: true), findsOneWidget);
    expect(find.textContaining('40k / 100k tokens used', findRichText: true), findsOneWidget);
    expect(find.textContaining('Cache hits\nConversation: 61.2% (30000 / 49000 input tokens)\nLatest response: 76.9% (30000 / 39000 input tokens)', findRichText: true), findsOneWidget);
    await leave();
    client.events.add({'task_id': 'task', ...task.events[3]!});
    client.events.add({'task_id': 'task', 'seq': 4, 'type': 'model.completed', 'data': {'usage': {'input_tokens': 59000, 'output_tokens': 1000, 'cached_input_tokens': 50000}}});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: 60%'), findsOneWidget);
    await hover();
    expect(find.textContaining('60% full', findRichText: true), findsOneWidget);
    expect(find.textContaining('Conversation: 74.1% (80000 / 108000 input tokens)', findRichText: true), findsOneWidget);
    expect(find.textContaining('Latest response: 84.7% (50000 / 59000 input tokens)', findRichText: true), findsOneWidget);
    await leave();
    client.events.add({'task_id': 'task', 'seq': 5, 'type': 'context.compacted', 'data': {'usage': {'input_tokens': 10000, 'output_tokens': 1000, 'cached_input_tokens': 0}}});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: unavailable'), findsOneWidget, reason: 'Compaction request usage describes the old context');
    await hover();
    expect(find.textContaining('Usage unavailable', findRichText: true), findsOneWidget);
    expect(find.textContaining('60k / 100k tokens used', findRichText: true), findsNothing);
    expect(find.textContaining('Conversation: 67.8% (80000 / 118000 input tokens)', findRichText: true), findsOneWidget);
    await leave();
    client.events.add({'task_id': 'task', 'seq': 6, 'type': 'model.completed', 'data': {'usage': {'input_tokens': 2000, 'output_tokens': 1000, 'cached_input_tokens': 0}}});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: 3%'), findsOneWidget);
    await hover();
    expect(find.textContaining('Conversation: 66.7% (80000 / 120000 input tokens)', findRichText: true), findsOneWidget);
    expect(find.textContaining('Latest response: 0.0% (0 / 2000 input tokens)', findRichText: true), findsOneWidget);
    await leave();
    for (final (seq, input, output, percent) in [(7, 100000, 5000, 100), (8, 0, 0, 0)]) {
      client.events.add({'task_id': 'task', 'seq': seq, 'type': 'model.completed', 'data': {'usage': {'input_tokens': input, 'output_tokens': output}}});
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Context usage: $percent%'), findsOneWidget);
    }
    expect(editor.controller!.text, 'Keep my draft');
    expect(editor.controller!.selection, selection);
    expect(editor.focusNode!.hasFocus, true);
    expect(client.sent, isEmpty);
    final fresh = DesktopTask('fresh', 'Fresh')..loaded = true..provider = 'gpt'..model = 'gpt-6.1-sol'..reasoning = 'low';
    session.project!.tasks.add(fresh);
    await tester.runAsync(() => session.select(session.project!, fresh));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: unavailable'), findsOneWidget, reason: 'Missing measurements must leave a discoverable control');
    await hover();
    expect(find.textContaining('Usage unavailable', findRichText: true), findsOneWidget);
    expect(find.textContaining('Cache hits', findRichText: true), findsNothing, reason: 'Missing data must not become a zero cache hit rate');
    await leave();
    await tester.runAsync(() => session.select(session.project!, task));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: 0%'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep my draft');
    client.events.add({'task_id': 'task', 'seq': 9, 'type': 'model.completed', 'data': {'usage': {'input_tokens': -1, 'output_tokens': 1000}}});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('one composer action switches between sending, stopping and follow-ups', (tester) async {
    await open(tester);
    Future<void> frame() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    IconButton action(String tooltip) => tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == tooltip));
    expect(action('Send message').onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'First message');
    await tester.pumpAndSettle();
    expect(action('Send message').onPressed, isNotNull);
    await tester.tap(find.byTooltip('Send message'));
    await frame();
    expect(client.sent.single['prompt'], 'First message');
    expect(find.byTooltip('Send message'), findsNothing);
    expect(find.byTooltip('Steer task'), findsNothing);
    expect(action('Stop task and clear pending messages').onPressed, isNotNull);
    for (final (mode, label) in [('steer', 'Steer task'), ('queue', 'Queue message')]) {
      session.deliveryMode = mode;
      await tester.enterText(find.byType(TextField), 'Follow up $mode');
      await frame();
      expect(find.byTooltip('Stop task and clear pending messages'), findsNothing);
      expect(action(label).onPressed, isNotNull);
      await tester.tap(find.byTooltip(label));
      await frame();
      expect(client.sent.last['prompt'], 'Follow up $mode');
      expect(client.sent.last['delivery'], mode);
      expect(find.byTooltip(label), findsNothing);
      expect(action('Stop task and clear pending messages').onPressed, isNotNull);
    }
    await tester.enterText(find.byType(TextField), '   ');
    await frame();
    session.providers.first['status'] = 'signed_out';
    client.events.add({'task_id': 'task', 'type': 'text.delta', 'delta': ''});
    await frame();
    expect(action('Stop task and clear pending messages').onPressed, isNotNull, reason: 'Stopping must remain possible after sign-out');
    await tester.tap(find.byTooltip('Stop task and clear pending messages'));
    await tester.pump();
    expect(client.cancelled, ['task']);
    client.events.add({'task_id': 'task', 'type': 'turn.cancelled', 'data': {}});
    await tester.pumpAndSettle();
    expect(find.byTooltip('Stop task and clear pending messages'), findsNothing);
    expect(action('Send message').onPressed, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '   ');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('MCP submenu preserves the draft and file chips and never submits the command', (tester) async {
    await open(tester);
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    await tester.enterText(find.byType(TextField), 'Keep /mcp tail ');
    controller.insertFile(TextRange.collapsed(controller.text.length), '/project/lib/main.dart');
    controller.selection = const TextSelection.collapsed(offset: 9);
    final before = tester.getRect(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(client.inventories, isEmpty, reason: 'The command suggestion alone does no discovery');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.inventories.single.verbose, false);
    expect(find.text('Loading MCP status…'), findsOneWidget);
    expect(controller.text, 'Keep  tail ${ComposerTextController.marker} ');
    expect(controller.files.single.path, '/project/lib/main.dart');
    expect(session.drafts['task'], controller.text);
    expect(client.sent, isEmpty);
    client.inventories.single.reply.complete({'servers': [
      {'name': 'dart', 'enabled': true, 'state': 'ready', 'tool_count': 12, 'auth_status': 'unsupported'},
      {'name': 'paused', 'enabled': false, 'state': 'disabled', 'tool_count': 0, 'auth_status': 'unsupported'},
    ]});
    await tester.pumpAndSettle();
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Auth unsupported'), findsNWidgets(2));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('dart')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.tap(find.text('dart'));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, true);
    expect(client.sent, isEmpty);
    expect(tester.getRect(find.byType(TextField)), before);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('dart'), findsNothing);
    expect(controller.files.single.path, '/project/lib/main.dart');
    await tester.enterText(find.byType(TextField), '/mcp');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    client.inventories.last.reply.complete({'servers': [{'name': 'dart', 'enabled': true, 'state': 'ready', 'tool_count': 1, 'auth_status': 'unsupported'}]});
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'dar');
    await tester.pumpAndSettle();
    expect(find.text('dart'), findsOneWidget);
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    client.events.add({'task_id': 'task', 'type': 'turn.completed', 'data': {}});
    await tester.pumpAndSettle();
    expect(client.sent.single['prompt'], 'dar');
    expect(find.text('dart'), findsNothing);
    expect(controller.text, isEmpty);
    await tester.enterText(find.byType(TextField), '@ma');
    await tester.pump(const Duration(milliseconds: 210));
    expect(client.searches.single.query, 'ma');
    client.searches.single.reply.complete({'paths': ['lib/main.dart'], 'truncated': false});
    await tester.pumpAndSettle();
    expect(find.text('lib/main.dart'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('MCP verbose shows tool and resource details during an unauthenticated running task', (tester) async {
    session.providers.first['status'] = 'signed_out';
    await open(tester);
    client.events.add({'task_id': 'task', 'type': 'turn.started', 'data': {}});
    Future<void> frame() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.enterText(find.byType(TextField), '/mcp verbose');
    final commandText = tester.widget<TextField>(find.byType(TextField)).controller!;
    commandText.selection = TextSelection(baseOffset: 0, extentOffset: commandText.text.length);
    await frame();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await frame();
    expect(client.inventories.single.verbose, true);
    client.inventories.single.reply.complete({'servers': [{
      'name': 'dart', 'enabled': true, 'state': 'ready', 'tool_count': 2, 'auth_status': 'configured_headers',
      'tools': ['analyze_files', 'hot_reload'],
      'resources': [{'name': 'docs', 'title': 'Documentation', 'uri': 'docs://index'}],
      'resource_templates': [], 'resource_templates_error': 'Unable to load resource templates',
    }]});
    await frame();
    expect(find.text('Configured HTTP headers'), findsOneWidget);
    expect(find.text('Connected · 2 tools'), findsOneWidget);
    expect(find.text('Tools: analyze_files, hot_reload'), findsOneWidget);
    expect(find.text('Resources: Documentation (docs://index)'), findsOneWidget);
    expect(find.text('Resource templates: Unable to load resource templates'), findsOneWidget);
    expect(client.sent, isEmpty);
    expect(session.task!.running, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frame();
    await tester.enterText(find.byType(TextField), '/mcp full');
    await frame();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await frame();
    expect(find.text('Usage: /mcp [verbose]'), findsOneWidget);
    expect(client.inventories, hasLength(1));
    expect(client.sent, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('MCP discovery retires late replies, refreshes config and cancels on navigation', (tester) async {
    await open(tester);
    Future<void> show() async {
      await tester.enterText(find.byType(TextField), '/mcp');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }
    await show();
    final obsolete = client.inventories.single;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(obsolete.cancellation.isCancelled, true);
    await show();
    obsolete.reply.complete({'servers': [{'name': 'obsolete'}]});
    client.inventories.last.reply.completeError(StateError('unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('obsolete'), findsNothing);
    expect(find.text('Unable to load MCP status. Retry'), findsOneWidget);
    await tester.tap(find.text('Unable to load MCP status. Retry'));
    await tester.pumpAndSettle();
    client.inventories.last.reply.complete({'servers': []});
    await tester.pumpAndSettle();
    expect(find.text('No MCP servers configured'), findsOneWidget);
    client.events.add({'type': 'mcp.config.reloaded', 'data': {}});
    await tester.pumpAndSettle();
    final refresh = client.inventories.last;
    refresh.reply.complete({'servers': [{'name': 'external', 'enabled': false, 'state': 'disabled', 'tool_count': 0, 'auth_status': 'unsupported'}]});
    await tester.pumpAndSettle();
    expect(find.text('external'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '@ma');
    await tester.pump(const Duration(milliseconds: 210));
    expect(find.text('external'), findsNothing);
    client.searches.single.reply.complete({'paths': ['lib/main.dart'], 'truncated': false});
    await tester.pumpAndSettle();
    expect(find.text('lib/main.dart'), findsOneWidget);
    await show();
    client.inventories.last.reply.complete({'servers': [{'name': 'external', 'enabled': false, 'state': 'disabled', 'tool_count': 0, 'auth_status': 'unsupported'}]});
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ordinary message with no matching server');
    await tester.pumpAndSettle();
    expect(find.text('external'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'ordinary message with no matching server');
    await show();
    final departing = client.inventories.last;
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    expect(departing.cancellation.isCancelled, true);
    departing.reply.complete({'servers': [{'name': 'departed'}]});
    await tester.pumpAndSettle();
    expect(find.text('departed'), findsNothing);
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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

  testWidgets('one model and reasoning menu selects new-task defaults and preserves existing-task restrictions', (tester) async {
    (session.providers.first['models'] as List).first['reasoning_levels'] = ['low', 'high'];
    (session.providers.first['models'] as List).add({'id': 'gpt-6-astra', 'default_reasoning': 'low', 'reasoning_levels': ['low', 'high']});
    session.task!.reasoningUpdates = true;
    final existing = session.task!;
    session.task = null;
    await session.refreshProviders();
    await open(tester);
    final menu = find.byTooltip('Model and reasoning effort');
    Finder item(String label) => find.ancestor(of: find.text(label), matching: find.byType(PopupMenuItem<String>));
    Future<void> frame() async { await tester.pump(); await tester.pump(const Duration(milliseconds: 300)); }
    expect(menu, findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.enterText(find.byType(TextField), 'Keep new draft');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('MODEL'), findsOneWidget);
    expect(find.text('REASONING EFFORT'), findsOneWidget);
    await tester.tap(item('gpt-6-astra'));
    await tester.pumpAndSettle();
    expect(session.modelId, 'gpt-6-astra');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep new draft');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(item('High'));
    await tester.pumpAndSettle();
    expect(session.reasoning, 'high');
    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    expect(session.modelId, 'gpt-6.1-sol');
    client.events.add({'task_id': 'task', 'type': 'turn.started', 'data': {}});
    await frame();
    await tester.tap(menu);
    await frame();
    expect(tester.widget<PopupMenuItem<String>>(item('gpt-6-astra')).enabled, false);
    expect(find.text('Start a new task to change models.'), findsOneWidget);
    expect(tester.widget<PopupMenuItem<String>>(item('High')).enabled, true);
    await tester.tap(item('High'));
    await frame();
    expect(session.reasoning, 'high');
    await tester.enterText(find.byType(TextField), 'Use more reasoning');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['reasoning'], 'high');
    expect(client.sent.single['delivery'], 'steer');

    session.task!.reasoningUpdates = false;
    client.events.add({'task_id': 'task', 'type': 'model.completed', 'data': {}});
    await tester.pump();
    await tester.tap(menu);
    await frame();
    expect(tester.widget<PopupMenuItem<String>>(item('Light')).enabled, false);
    expect(find.text('Reasoning effort is fixed for this task.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frame();
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
    final newDraft = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(newDraft.text, 'Please \uFFFC ');
    expect(newDraft.serializePrompt(), 'Please [my file.md](notes/my file.md) ');
    expect(find.text('my file.md'), findsOneWidget);
    expect(session.drafts['checkout'], newDraft.text);
    expect(session.fileDrafts['checkout']!.single.path, 'notes/my file.md');

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
    expect(newDraft.text, 'Use \uFFFC ');
    expect(newDraft.serializePrompt(), 'Use [desktop](packages/desktop/) ');
    expect(find.text('desktop'), findsOneWidget);
    expect(session.drafts['checkout'], newDraft.text);
    expect(client.sent, isEmpty);

    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Inspect @mainZZ afterwards');
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    controller.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.searches.last.query, 'main');
    client.searches.last.reply.complete({'paths': ['lib/main.dart'], 'truncated': false});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(controller.text, 'Inspect \uFFFC afterwards');
    expect(controller.serializePrompt(), 'Inspect [main.dart](lib/main.dart) afterwards');
    expect(controller.selection.baseOffset, 'Inspect \uFFFC '.length);
    expect(session.drafts[existing.id], controller.text);
    expect(client.sent, isEmpty);
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    final restoredNew = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(restoredNew.serializePrompt(), 'Use [desktop](packages/desktop/) ');
    expect(find.text('desktop'), findsOneWidget);
    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    final restored = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(restored.serializePrompt(), 'Inspect [main.dart](lib/main.dart) afterwards');
    client.rejectSend = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['task_id'], existing.id);
    expect(client.sent.single['prompt'], 'Inspect [main.dart](lib/main.dart) afterwards');
    expect(restored.files.single.path, 'lib/main.dart');
    expect(session.fileDrafts[existing.id]!.single.path, 'lib/main.dart');
    client.rejectSend = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, hasLength(2));
    expect(restored.text, isEmpty);
    expect(session.fileDrafts[existing.id], isNull);
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

  testWidgets('file chips copy and cut as paths and keep identities through undo', (tester) async {
    String? clipboard;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Compare @first');
    await tester.pump(const Duration(milliseconds: 200));
    client.searches.last.reply.complete({'paths': ['lib/first.dart'], 'truncated': false});
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 600));
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    final original = controller.serializePrompt();
    controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(clipboard, original);
    controller.selection = const TextSelection(baseOffset: 8, extentOffset: 9);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(const Duration(milliseconds: 600));
    expect(clipboard, '[first.dart](lib/first.dart)');
    expect(controller.files, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.serializePrompt(), original);
    expect(controller.files.single.path, 'lib/first.dart');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.files, isEmpty);
    expect(controller.serializePrompt(), 'Compare  ');
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
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(controller.text, '\uFFFC ');
    expect(controller.serializePrompt(), '[my file.md](notes/my file.md) ');
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
  final cancelled = <String>[];
  List<Json> providers = [];
  final searches = <({String cwd, String query, CancellationToken cancellation, Completer<Json> reply})>[];
  final inventories = <({bool verbose, CancellationToken cancellation, Completer<Json> reply})>[];
  @override Future<Json> mcpInventory({bool verbose = false, String? server, required CancellationToken cancellation}) {
    final reply = Completer<Json>();
    inventories.add((verbose: verbose, cancellation: cancellation, reply: reply));
    return reply.future;
  }
  bool rejectSend = false;
  @override Future<Json> searchFiles(String cwd, String query, {required CancellationToken cancellation}) {
    final reply = Completer<Json>();
    searches.add((cwd: cwd, query: query, cancellation: cancellation, reply: reply));
    return reply.future;
  }
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'providers.list') return {'providers': providers, 'default_provider': 'gpt'};
    if (method == 'task.cancel') {
      cancelled.add(params['task_id'] as String);
      return {};
    }
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
