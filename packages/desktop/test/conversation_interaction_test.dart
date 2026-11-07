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

  Future<void> open(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: MediaQuery(
        data: const MediaQueryData(size: Size(1000, 1000), disableAnimations: true), child: Scaffold(body: child))));
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
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(displayed().width, 80);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(displayed().width, 80, reason: 'Right must stop at this message, without wrapping or crossing into the next');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(preview, findsNothing, reason: 'Changing images resets zoom to fit');
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
    expect(find.text('Worked'), findsOneWidget);
    expect(find.text('Read 1 file'), findsNothing);
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
      await precacheImage(FileImage(saved), tester.element(mainImage));
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
    expect(find.text('3 / 3'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
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
        'server': 'images', 'tool': 'read', 'status': 'completed', 'arguments': {'path': '/image'},
        if (native) 'contentItems': [
          {'type': 'inputText', 'text': 'Image result'}, {'type': 'inputImage', 'imageUrl': 'data:image/png;base64,$first'},
        ] else 'result': {'content': [
          {'type': 'text', 'text': 'Image result'}, {'type': 'image', 'data': first, 'mimeType': 'image/png'},
        ]},
      };
      final tool = conversation(task).single.tool!;
      await open(tester, ConversationToolCall(tool: tool, onExpand: () {}));
      await tester.tap(find.text('Read /image'));
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
        directory: '', onExpand: () {})));
    expect(find.byType(ConversationImage), findsNothing, reason: 'Collapsed inspections must not decode images');
    await tester.runAsync(() async {
      await tester.tap(find.text('Viewed 2 images'));
      await tester.pump();
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(image.image, tester.element(find.byType(Scaffold)));
      }
    });
    await tester.pumpAndSettle();
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

  testWidgets('live activity stays collapsed and respects a closed JavaScript cell', (tester) async {
    final task = DesktopTask('activity', 'Activity')..loaded = true..running = true;
    void update(int calls) {
      task.messages['cell'] = {'id': 'cell', 'type': 'dynamicToolCall', 'tool': 'functions.exec', 'startedAtMs': 1,
        'order': 0, 'status': 'inProgress', 'arguments': 'await tools.read()'};
      for (var index = 0; index < calls; index++) {
        task.messages['read$index'] = {'id': 'read$index', 'type': 'dynamicToolCall', 'tool': 'read_file',
          'startedAtMs': 1, 'order': index + 1, 'parentCallId': 'cell', 'status': 'completed', 'arguments': {'path': '/file$index'}};
      }
    }
    Widget transcript() => ConversationTranscript(task: task, directory: '', onRetry: () {});
    update(1);
    await open(tester, transcript());
    expect(find.byTooltip('View code'), findsNothing, reason: 'Running activity must not force its group open');
    await tester.tap(find.textContaining('Used 1', findRichText: true));
    await tester.pump();
    expect(find.text('read_file'), findsNothing, reason: 'The work log does not force an individual call open');
    await tester.tap(find.text('JavaScript').first);
    await tester.pumpAndSettle();
    expect(find.text('read_file'), findsOneWidget);
    await tester.tap(find.text('JavaScript').first);
    await tester.pump();
    update(2);
    await open(tester, transcript());
    expect(find.text('read_file'), findsNothing, reason: 'New calls must not reopen a closed cell');
    await tester.tap(find.textContaining('Used 1', findRichText: true));
    await tester.pump();
    await tester.tap(find.textContaining('Used 1', findRichText: true));
    await tester.pump();
    expect(find.text('read_file'), findsNothing, reason: 'Remounting the cell must preserve the explicit closed choice');
    await tester.tap(find.text('JavaScript').first);
    await tester.pump();
    expect(find.text('read_file'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('JavaScript child disclosure choices belong to each call', (tester) async {
    ToolActivity cell(bool append) => ToolActivity('cell', 'functions.exec', {'code': 'await tools.read()'})
      ..status = 'done'
      ..children.addAll([
        ToolActivity('first', 'read_file', {'path': '/first'})..status = 'done'..output = 'First result',
        if (append) ToolActivity('second', 'read_file', {'path': '/second'})..status = 'done'..output = 'Second result',
      ]);
    await open(tester, ConversationToolCall(tool: cell(false), onExpand: () {}));
    await tester.tap(find.text('JavaScript'));
    await settleFormatting(tester);
    await tester.tap(find.text('read_file'));
    await settleFormatting(tester);
    expect(find.textContaining('First result', findRichText: true), findsOneWidget);
    await open(tester, ConversationToolCall(tool: cell(true), onExpand: () {}));
    expect(find.textContaining('First result', findRichText: true), findsOneWidget);
    expect(find.textContaining('Second result', findRichText: true), findsNothing, reason: 'A newly mounted call must start collapsed');
    await tester.tap(find.text('read_file').first);
    await settleFormatting(tester);
    expect(find.textContaining('First result', findRichText: true), findsNothing);
    await tester.tap(find.text('JavaScript'));
    await settleFormatting(tester);
    await tester.tap(find.text('JavaScript'));
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
