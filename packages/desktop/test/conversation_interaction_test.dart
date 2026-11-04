import 'dart:convert';
import 'dart:ui' as ui;

import 'package:desktop/composer_attachments.dart';
import 'package:desktop/conversation.dart';
import 'package:desktop/conversation_markdown.dart';
import 'package:desktop/image_preview.dart';
import 'package:desktop/conversation_tools.dart';
import 'package:desktop/conversation_data.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';

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
