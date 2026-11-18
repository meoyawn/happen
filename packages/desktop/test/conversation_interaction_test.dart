import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop/composer_attachments.dart';
import 'package:desktop/conversation.dart';
import 'package:desktop/conversation_markdown.dart';
import 'package:desktop/image_preview.dart';
import 'package:desktop/conversation_tools.dart';
import 'package:desktop/conversation_data.dart';
import 'package:desktop/conversation_images.dart';
import 'package:desktop/file_reference.dart';
import 'package:desktop/generated_image_loading.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai/src/tools.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';

void main() {
  late String first, second;
  setUpAll(() async {
    Future<String> png(int width, int height, Color color) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(color, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose(); picture.dispose();
      return base64Encode(bytes!.buffer.asUint8List());
    }
    first = await png(120, 80, Colors.blue);
    second = await png(80, 120, Colors.green);
  });

  Future<void> settleFormatting(WidgetTester tester) async {
    // Real formatter isolates cannot make progress on the widget fake clock.
    await tester.runAsync(() async {
      final timeout = TimeoutCancellationToken(const Duration(seconds: 5));
      try {
        await tester.pump();
        while (find.descendant(of: find.byType(ConversationData), matching: find.byType(CircularProgressIndicator)).evaluate().isNotEmpty) {
          await cancellableDelay(const Duration(milliseconds: 5), timeout);
          await tester.pump();
        }
      } finally { timeout.cancel(); }
    });
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, Widget child, {bool disableAnimations = true}) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: MediaQuery(
        data: MediaQueryData(size: const Size(1000, 1000), disableAnimations: disableAnimations), child: Scaffold(body: child))));
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(image.image, tester.element(find.byType(Scaffold)));
      }
    });
    await settleFormatting(tester);
  }

  for (final surface in ['user', 'composer', 'assistant', 'tool']) {
    testWidgets('$surface image arrows stay within one message', (tester) async {
      final parts = [
        {'type': 'image', 'name': 'First', 'data': first, 'mime_type': 'image/png'},
        {'type': 'image', 'name': 'Second', 'data': second, 'mime_type': 'image/png'},
      ];
      Widget message(List<Map<String, dynamic>> images) => switch (surface) {
        'assistant' => ConversationMarkdown(directory: '', text: images.map((image) =>
          '![${image['name']}](data:image/png;base64,${image['data']})').join('\n\n')),
        'tool' => ConversationImageParts(parts: images, directory: ''),
        _ => AttachmentRail(attachments: images, composer: surface == 'composer'),
      };
      final task = DesktopTask('images', 'Images')..loaded = true;
      for (var index = 0; index < 2; index++) {
        task.messages['user$index'] = {'id': 'user$index', 'type': 'userMessage', 'order': index, 'startedAtMs': index,
          'content': [{'type': 'text', 'text': 'Message $index'}, ...index == 0 ? parts : [parts.first]]};
      }
      await open(tester, surface == 'user'
        ? ConversationTranscript(task: task, directory: '', onRetry: () {})
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [message(parts), message([parts.first])]));
      await tester.runAsync(() async {
        await tester.tap(find.byWidgetPredicate((widget) => widget is ConversationImage && widget.label == 'Second'));
        await tester.pump();
        final preview = tester.widget<ImagePreview>(find.byType(ImagePreview));
        for (final image in preview.images) {
          await precacheImage(image.provider, tester.element(find.byType(Scaffold).first));
        }
      });
      await tester.pumpAndSettle();
      final preview = find.byType(ImagePreview);
      ui.Image displayed() => tester.widget<RawImage>(find.descendant(of: preview, matching: find.byType(RawImage))).image!;
      expect(displayed().width, 80);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(displayed().width, 120, reason: 'Left must show the previous image in this message');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(displayed().width, 120);
      expect(find.byTooltip('Previous image'), findsNothing);
      await tester.tap(find.byTooltip('Next image'));
      await tester.pumpAndSettle();
      expect(displayed().width, 80);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(displayed().width, 80, reason: 'Right must stop at this message, without wrapping or crossing into the next');
      expect(find.byTooltip('Next image'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(preview, findsNothing, reason: 'Escape closes the preview after navigating');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('generated galleries stay visible after work folds and preview all conversation images', (tester) async {
    late Directory directory;
    late File saved;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('generated-images-');
      saved = await File('${directory.path}/saved image.png').writeAsBytes(base64Decode(second));
    });
    addTearDown(() => directory.delete(recursive: true));
    final task = DesktopTask('generated', 'Generated images')..loaded = true;
    task.turns['turn'] = {'id': 'turn', 'status': 'completed'};
    task.messages.addAll({
      'read': {'id': 'read', 'type': 'dynamicToolCall', 'turnId': 'turn', 'order': 0,
        'tool': 'read_file', 'arguments': {'path': '/input'}, 'status': 'completed'},
      'first': {'id': 'first', 'type': 'imageGeneration', 'turnId': 'turn', 'order': 1, 'status': 'completed', 'result': first},
      'second': {'id': 'second', 'type': 'imageGeneration', 'turnId': 'turn', 'order': 2,
        'status': 'completed', 'savedPath': saved.path, 'result': first},
      'commentary': {'id': 'commentary', 'type': 'agentMessage', 'turnId': 'turn', 'order': 3,
        'text': 'Making another image', 'phase': 'commentary'},
      'third': {'id': 'third', 'type': 'imageGeneration', 'turnId': 'turn', 'order': 4, 'status': 'completed', 'result': first},
      'answer': {'id': 'answer', 'type': 'agentMessage', 'turnId': 'turn', 'order': 5,
        'text': 'Your images are ready', 'phase': 'final_answer'},
    });
    await open(tester, ConversationTranscript(task: task, directory: '', onRetry: () {}));
    expect(find.text('2 previous messages'), findsOneWidget);
    expect(find.text('read file'), findsNothing);
    expect(find.byType(ConversationGeneratedImages), findsNWidgets(2));
    final gallery = find.ancestor(
      of: find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'Show generated image 2'),
      matching: find.byType(ConversationGeneratedImages));
    final mainImage = find.descendant(of: gallery, matching: find.byWidgetPredicate((widget) =>
      widget is ConversationImage && widget.label == 'Generated image'));
    await tester.runAsync(() async {
      await tester.tap(find.byWidgetPredicate((widget) => widget is Semantics &&
        widget.properties.label == 'Show generated image 2'));
      await tester.pump();
      final image = tester.widget<Image>(find.descendant(of: mainImage, matching: find.byType(Image)));
      await precacheImage(image.image, tester.element(mainImage));
    });
    await tester.pumpAndSettle();
    expect(tester.widget<ConversationImage>(mainImage).source, saved.path);
    await tester.runAsync(() async {
      await tester.tap(mainImage);
      await tester.pump();
      final preview = tester.widget<ImagePreview>(find.byType(ImagePreview));
      for (final image in preview.images) {
        await precacheImage(image.provider, tester.element(find.byType(Scaffold).first));
      }
    });
    await tester.pumpAndSettle();
    final preview = find.byType(ImagePreview);
    ui.Image displayed() => tester.widget<RawImage>(find.descendant(of: preview, matching: find.byType(RawImage))).image!;
    expect(displayed().width, 80, reason: 'The saved original takes precedence over the inline result');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(displayed().width, 120, reason: 'The viewer includes images beyond this inline gallery');
    expect(find.byTooltip('Next image'), findsNothing);
    expect(find.byTooltip('Previous image'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(displayed().width, 120);
    await tester.tap(find.byTooltip('Close image preview'));
    await tester.pumpAndSettle();
    expect(preview, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('image generation stops its placeholder on interruption and preserves completed output', (tester) async {
    final task = DesktopTask('generation', 'Generation')..loaded = true..running = true;
    task.turns['turn'] = {'id': 'turn', 'status': 'inProgress'};
    task.messages['image'] = {'id': 'image', 'type': 'imageGeneration', 'turnId': 'turn',
      'status': 'inProgress', 'result': ''};
    Widget transcript() => ConversationTranscript(task: task, directory: '', onRetry: () {});
    await open(tester, transcript());
    expect(find.byType(GeneratedImageLoading), findsOneWidget);
    task.running = false;
    task.turns['turn'] = {'id': 'turn', 'status': 'interrupted'};
    await open(tester, transcript());
    expect(find.byType(GeneratedImageLoading), findsNothing);
    task.messages['image'] = {...task.messages['image']!, 'status': 'completed', 'result': first};
    await open(tester, transcript());
    expect(find.byWidgetPredicate((widget) => widget is ConversationImage && widget.label == 'Generated image'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final native in [false, true]) {
    testWidgets('${native ? 'dynamic' : 'MCP'} tool responses render their images beside text', (tester) async {
      final task = DesktopTask('tool-images', 'Tool images');
      task.messages['tool'] = {'id': 'tool', 'type': native ? 'dynamicToolCall' : 'mcpToolCall',
        if (!native) 'server': 'images', 'tool': 'read', 'status': 'completed', 'arguments': {'path': '/image'},
        if (native) 'contentItems': [
          {'type': 'inputText', 'text': 'Image result'}, {'type': 'inputImage', 'imageUrl': 'data:image/png;base64,$first'},
        ] else 'result': {'content': [
          {'type': 'text', 'text': 'Image result'}, {'type': 'image', 'data': first, 'mimeType': 'image/png'},
        ]},
      };
      final tool = conversation(task).single.tool!;
      await open(tester, ConversationToolCall(tool: tool, onExpand: () {}));
      await tester.tap(find.text(native ? 'read' : 'images · read'));
      await settleFormatting(tester);
      expect(find.textContaining('Image result', findRichText: true), findsOneWidget);
      final image = find.byWidgetPredicate((widget) => widget is ConversationImage && widget.label == 'Tool image');
      expect(image, findsOneWidget);
      await tester.runAsync(() async {
        for (final widget in tester.widgetList<Image>(find.descendant(of: image, matching: find.byType(Image)))) {
          await precacheImage(widget.image, tester.element(image));
        }
      });
      await tester.pumpAndSettle();
      expect(tester.widget<RawImage>(find.descendant(of: image, matching: find.byType(RawImage))).image!.width, 120);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('inspected thumbnails and previews retain the recorded bytes after the source is deleted', (tester) async {
    late Directory root;
    late DesktopTask task;
    late _RecordedImageClient client;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('inspected-images-');
      final source = await File('${root.path}/reference.png').writeAsBytes(base64Decode(first));
      final cancellation = CancellationToken();
      final tools = HostTools(root.path, cancellation);
      Json? captured;
      try {
        await tools.call('view_image', {'path': source.path}, cancellation: cancellation, callId: 'current',
          onItem: (phase, item) async { if (phase == 'completed') captured = item; });
      } finally { cancellation.cancel(); await tools.close(); }
      await source.delete();
      final id = newId(), store = TaskStore(root.path, id);
      try {
        store.append('task.created', {'task_id': id, 'cwd': root.path, 'provider': 'openai', 'model': 'fixture'},
          metadata: {'config': {'cwd': root.path, 'provider': 'openai', 'model': 'fixture'}});
        Json event(String type, Json value) => {'type': 'event_msg', 'payload': {'type': type, 'turn_id': 'turn', ...value}};
        store.native.append([
          event('task_started', {'started_at': 1}),
          event('item_completed', {'item': captured!}),
          event('item_completed', {'item': {'id': 'historical', 'type': 'ImageView', 'path': source.path}}),
          {'type': 'response_item', 'payload': {'type': 'custom_tool_call_output', 'call_id': 'cell',
            'output': [{'type': 'input_image', 'image_url': 'data:image/png;base64,$second'}]}},
          event('task_complete', {'completed_at': 2}),
        ]);
      } finally { store.close(); }
      client = _RecordedImageClient(root.path);
      final page = await readSession(root.path, id, 'thread/items/list', {}, cancellation: CancellationToken());
      task = DesktopTask(id, 'Inspected images');
      for (final raw in page['data'] as List) {
        final item = jsonObject(raw['item']);
        task.messages[item['id'] as String] = {...item, 'turnId': raw['turnId'], 'order': task.messages.length};
      }
    });
    addTearDown(() => root.delete(recursive: true));
    await open(tester, ConversationDataScope(client: client,
      child: ConversationInspectedImages(tools: conversation(task).map((entry) => entry.tool!).toList(),
        directory: '', onExpand: () {})), disableAnimations: false);
    expect(find.byType(ConversationImage), findsNothing, reason: 'Collapsed inspections must not decode images');
    final inspection = find.byType(ConversationInspectedImages);
    final collapsed = tester.getSize(inspection).height;
    await tester.runAsync(() async {
      await tester.tap(find.text('Viewed 2 images'));
      await tester.pump();
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(image.image, tester.element(find.byType(Scaffold)));
      }
    });
    expect(tester.getSize(inspection).height, closeTo(collapsed, .5));
    await tester.pump(const Duration(milliseconds: 65));
    final opening = tester.getSize(inspection).height;
    await tester.pumpAndSettle();
    expect(opening, inExclusiveRange(collapsed, tester.getSize(inspection).height));
    expect(tester.widgetList<RawImage>(find.byType(RawImage)).where((image) => image.image != null), hasLength(2));
    await tester.runAsync(() async {
      await tester.tap(find.byType(ConversationImage).last);
      await tester.pump();
      final preview = tester.widget<ImagePreview>(find.byType(ImagePreview));
      for (final image in preview.images) {
        await precacheImage(image.provider, tester.element(find.byType(Scaffold).first));
      }
    });
    await tester.pumpAndSettle();
    final preview = find.byType(ImagePreview);
    expect(tester.widget<RawImage>(find.descendant(of: preview, matching: find.byType(RawImage))).image!.width, 80);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.descendant(of: preview, matching: find.byType(RawImage))).image!.width, 120);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tool activity animates and opens file references independently of details', (tester) async {
    final task = DesktopTask('file-activity', 'File activity')..loaded = true;
    addTearDown(task.liveText.dispose);
    const commands = [
      r"rg -n 'ThemeData\(|fontFamily:|colorScheme:' lib/theme.dart | head -20",
      "ls 'build/artifacts'",
      "sed -n '1,40p' 'notes#1'",
      'git diff --check',
      'git status --short',
    ];
    for (final (index, command) in commands.indexed) {
      final id = 'command-$index';
      task.messages[id] = {'id': id, 'type': 'commandExecution', 'status': 'completed',
        'order': index, 'cwd': '/project/execution', 'command': '/bin/zsh -lc $command',
        'commandActions': [{'type': 'unknown', 'command': command}]};
    }
    task.messages['edit'] = {'id': 'edit', 'type': 'fileChange', 'status': 'completed', 'order': commands.length,
      'changes': [{'path': 'lib/main.dart', 'kind': {'type': 'update'}, 'diff': '@@ -11 +11 @@\n-old\n+new\n'}]};
    ConversationFileLocation? opened;
    Future<void> render({bool reducedMotion = false}) => tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion), child: child!),
      home: Scaffold(body: ConversationFileScope(onOpen: (location) => opened = location,
        child: ConversationTranscript(task: task, directory: '/project', onRetry: () {})))));
    await render();
    final run = find.byType(ConversationToolRun);
    double height() => tester.getSize(run).height;
    final collapsed = height();
    final summary = find.text('Edited a file, read files, ran commands');
    expect(summary, findsOneWidget);
    expect(find.text('notes#1'), findsNothing);
    await tester.tap(summary);
    await tester.pump();
    expect(height(), closeTo(collapsed, .01));
    await tester.pump(const Duration(milliseconds: 70));
    final opening = height();
    expect(opening, greaterThan(collapsed));
    await tester.pumpAndSettle();
    final expanded = height();
    expect(expanded, greaterThan(opening));
    expect(find.text(r'Searched for ThemeData\(|fontFamily:|colorScheme: in'), findsOneWidget);
    expect(find.text('Listed files in artifacts'), findsOneWidget);
    expect(find.text('+1 −1'), findsOneWidget);
    expect(find.text('git diff --check'), findsOneWidget);
    for (final (label, path, line) in [
      ('theme.dart', '/project/execution/lib/theme.dart', null),
      ('notes#1', '/project/execution/notes#1', null),
      ('main.dart', '/project/lib/main.dart', 11),
    ]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(opened, (path: path, line: line));
    }
    expect(find.text('Command'), findsNothing);
    await tester.tap(summary);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(height(), inExclusiveRange(collapsed, expanded));
    expect(find.text('notes#1'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('notes#1'), findsNothing);
    await render(reducedMotion: true);
    await tester.tap(summary);
    await tester.pump();
    expect(height(), closeTo(expanded, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live tool runs follow public headings and progress while detail rows stay open', (tester) async {
    final task = DesktopTask('activity', 'Activity')..loaded = true..running = true;
    addTearDown(task.liveText.dispose);
    const turn = 'turn';
    task.turns[turn] = {'id': turn, 'status': 'inProgress'};
    void notify(String method, Json params, {String turnId = turn}) => applyThreadNotification(task.messages,
      {'method': method, 'params': {'turnId': turnId, ...params}});
    void item(Json item, {bool live = false}) => notify(live ? 'item/started' : 'item/completed', {'item': item});
    Widget transcript() => ConversationTranscript(task: task, directory: '', onRetry: () {});

    item({'id': 'cell', 'type': 'dynamicToolCall', 'namespace': 'functions', 'tool': 'exec',
      'status': 'inProgress', 'arguments': 'wrapper source'}, live: true);
    item({'id': 'skill', 'type': 'commandExecution', 'command': 'cat flutter/SKILL.md',
      'commandActions': [{'type': 'read', 'path': 'flutter/SKILL.md'}], 'parentCallId': 'cell', 'status': 'completed'});
    item({'id': 'version', 'type': 'commandExecution', 'command': 'flutter --version', 'status': 'completed'});
    item({'id': 'commentary', 'type': 'agentMessage', 'text': 'Checking the browser layout.', 'phase': 'commentary'});
    item({'id': 'browser', 'type': 'dynamicToolCall', 'tool': 'client__browser_snapshot', 'status': 'completed'});
    item({'id': 'search', 'type': 'webSearch', 'query': 'Flutter layouts'});
    item({'id': 'command', 'type': 'commandExecution', 'command': 'flutter test', 'status': 'failed',
      'aggregatedOutput': 'Layout check failed', 'exitCode': 1});
    item({'id': 'reasoning', 'type': 'reasoning'}, live: true);
    notify('item/reasoning/textDelta', {'itemId': 'reasoning', 'delta': '**Raw reasoning**'});
    for (final delta in ['**Checking', ' the layout**\nLooking for the cause.']) {
      notify('item/reasoning/summaryTextDelta', {'itemId': 'reasoning', 'summaryIndex': 1, 'delta': delta});
    }

    await open(tester, transcript());
    expect(find.text('Loaded a tool, ran a command'), findsOneWidget);
    expect(find.text('Raw reasoning'), findsNothing);
    expect(find.text('Checking the layout'), findsOneWidget);
    expect(find.text('Searched the web · Flutter layouts'), findsNothing);
    await tester.tap(find.text('Checking the layout'));
    await tester.pumpAndSettle();
    expect(find.text('Inspected the Browser page'), findsOneWidget);
    expect(find.text('Searched the web · Flutter layouts'), findsOneWidget);
    expect(find.text('JavaScript'), findsNothing);
    await tester.tap(find.text('Command failed (flutter test)'));
    await tester.pumpAndSettle();
    expect(find.text('Layout check failed'), findsOneWidget);

    const call = {'id': 'call', 'type': 'mcpToolCall', 'server': 'catalog', 'tool': 'lookup', 'arguments': {'query': 'layout'}};
    item({...call, 'status': 'inProgress'}, live: true);
    notify('item/mcpToolCall/progress', {'itemId': 'call', 'message': 'Reading the catalog'});
    notify('item/mcpToolCall/progress', {'itemId': 'call', 'message': 'Wrong turn'}, turnId: 'other');
    await open(tester, transcript());
    expect(find.text('Reading the catalog'), findsNWidgets(2));
    expect(find.text('Wrong turn'), findsNothing);
    for (final id in ['call', 'second-call']) {
      item({...call, 'id': id, 'status': 'completed', 'result': {'content': [{'type': 'text', 'text': 'Guide found'}]}});
    }
    notify('item/mcpToolCall/progress', {'itemId': 'call', 'message': 'Late progress'});
    await open(tester, transcript());
    expect(find.text('Reading the catalog'), findsNothing);
    expect(find.text('Late progress'), findsNothing);
    expect(find.text('Checking the layout'), findsOneWidget);
    expect(find.text('Layout check failed'), findsOneWidget);
    await tester.tap(find.text('catalog · lookup · 2 calls'));
    await tester.pumpAndSettle();
    expect(find.text('catalog · lookup'), findsNWidgets(2));
    await tester.ensureVisible(find.text('catalog · lookup').first);
    await tester.tap(find.text('catalog · lookup').first);
    await settleFormatting(tester);
    expect(find.text('Guide found'), findsOneWidget);

    item({'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text': 'Layout checked.'}, live: true);
    await open(tester, transcript());
    expect(find.text('8 previous messages'), findsOneWidget);
    expect(find.text('Checking the layout'), findsNothing);
    expect(find.text('Layout checked.', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('JavaScript child disclosure choices belong to each call', (tester) async {
    final task = DesktopTask('cell-details', 'Cell details');
    addTearDown(task.liveText.dispose);
    ToolActivity cell(bool append) {
      task.messages['cell'] = {'id': 'cell', 'type': 'dynamicToolCall', 'tool': 'exec', 'namespace': 'functions',
        'arguments': 'await tools.read()', 'status': 'failed', 'order': 0};
      for (final (index, id, result) in [(1, 'first', 'First result'), if (append) (2, 'second', 'Second result')]) {
        task.messages[id] = {'id': id, 'type': 'dynamicToolCall', 'tool': 'read_file', 'status': 'completed',
          'parentCallId': 'cell', 'arguments': {'path': '/$id'}, 'order': index,
          'contentItems': [{'type': 'inputText', 'text': result}]};
      }
      return conversation(task).single.tool!;
    }
    await open(tester, ConversationToolCall(tool: cell(false), onExpand: () {}));
    await tester.tap(find.text('JavaScript failed'));
    await settleFormatting(tester);
    await tester.tap(find.text('read file'));
    await settleFormatting(tester);
    expect(find.textContaining('First result', findRichText: true), findsOneWidget);
    await open(tester, ConversationToolCall(tool: cell(true), onExpand: () {}));
    expect(find.textContaining('First result', findRichText: true), findsOneWidget);
    expect(find.textContaining('Second result', findRichText: true), findsNothing, reason: 'A newly mounted call must start collapsed');
    await tester.tap(find.text('read file').first);
    await settleFormatting(tester);
    expect(find.textContaining('First result', findRichText: true), findsNothing);
    await tester.tap(find.text('JavaScript failed'));
    await settleFormatting(tester);
    await tester.tap(find.text('JavaScript failed'));
    await settleFormatting(tester);
    expect(find.textContaining('First result', findRichText: true), findsNothing);
    expect(find.textContaining('Second result', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _RecordedImageClient implements AgentClient {
  _RecordedImageClient(this.directory);
  final String directory;
  @override
  Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) =>
    readSession(directory, params['threadId'] as String, method, params, cancellation: cancellation);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
