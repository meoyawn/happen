import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'dart:ui' as ui;

import 'package:desktop/conversation.dart';
import 'package:desktop/conversation_markdown.dart';
import 'package:desktop/inline_reference.dart';
import 'package:desktop/image_preview.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';

void main() {
  testWidgets('skill links render the Harness glyph and label in messages while code and web links stay ordinary', (tester) async {
    final task = DesktopTask('skills', 'Skills')..events.addAll({
      1: {'seq': 1, 'type': 'input.committed', 'data': {'item': {
        'role': 'user', 'content': [{'type': 'text', 'text': r'Use [$dart](/skills/dart/SKILL.md) with [guide](https://example.com/SKILL.md).'}],
      }}},
      2: {'seq': 2, 'type': 'model.completed', 'data': {'output': [
        {'content': [{'type': 'text', 'text': r'Loaded [Dart](file:///skills/dart/SKILL.md). Example: `[$code](/skills/code/SKILL.md)`'}]},
      ]}},
    });
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      ConversationTranscript(task: task, directory: '/project', onRetry: () {}))));
    await tester.pumpAndSettle();
    expect(find.byType(SkillIcon), findsNWidgets(2));
    expect(find.textContaining(r'$dart', findRichText: true), findsOneWidget);
    expect(find.textContaining('Dart', findRichText: true), findsOneWidget);
    expect(find.byTooltip('/skills/dart/SKILL.md'), findsOneWidget);
    expect(find.textContaining(r'[$code](/skills/code/SKILL.md)', findRichText: true), findsOneWidget);
    expect(find.textContaining('guide', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> open(WidgetTester tester, DesktopTask task, {Size size = const Size(1100, 1400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff325e57))),
      home: Scaffold(body: ConversationTranscript(task: task, directory: '/project', onRetry: () {})),
    ));
  }

  testWidgets('retry clears the resolved failure from live and reopened conversations', (tester) async {
    final task = DesktopTask('retry', 'Retry')..loaded = true;
    task.events.addAll({
      1: {'seq': 1, 'type': 'turn.started', 'data': {}},
      2: {'seq': 2, 'type': 'input.committed', 'data': {'item': {
        'role': 'user', 'content': [{'type': 'text', 'text': 'Finish the work'}],
      }}},
      3: {'seq': 3, 'type': 'turn.failed', 'data': {'error': 'HTTP response headers timed out'}},
    });
    var retries = 0;
    Widget transcript(DesktopTask current) => MaterialApp(home: Scaffold(body: ConversationTranscript(
      task: current, directory: '/project', onRetry: () {},
      onRetryTurn: () { retries++; current.running = true; },
    )));
    await tester.pumpWidget(transcript(task));
    await tester.pumpAndSettle();
    expect(find.text('HTTP response headers timed out'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpWidget(transcript(task));
    await tester.pump();
    expect(retries, 1);
    expect(find.text('Something went wrong'), findsNothing);

    task.running = false;
    task.events.addAll({
      4: {'seq': 4, 'type': 'turn.started', 'data': {}},
      5: {'seq': 5, 'type': 'model.started', 'data': {'assistantMessageID': 'msg_reply'}},
      6: {'seq': 6, 'type': 'model.completed', 'data': {'assistantMessageID': 'msg_reply', 'output': [
        {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Work completed'}]},
      ]}},
      7: {'seq': 7, 'type': 'turn.completed', 'data': {}},
    });
    await tester.pumpWidget(transcript(task));
    await tester.pumpAndSettle();
    expect(find.text('Work completed', findRichText: true), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
    expect(task.messages.values.where((message) => message['outcome'] == 'failed'), hasLength(1));

    final reopened = DesktopTask(task.id, task.title)..loaded = true
      ..messages.addEntries(task.messages.entries.toList().reversed);
    await tester.pumpWidget(transcript(reopened));
    await tester.pumpAndSettle();
    expect(find.text('Work completed', findRichText: true), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);

    reopened.messages['new-failure'] = {
      'id': 'new-failure', 'type': 'idle', 'metadata': {'seq': 100},
      'time': {'created': 100}, 'outcome': 'failed', 'error': {'message': 'New failure'},
    };
    await tester.pumpWidget(transcript(reopened));
    await tester.pumpAndSettle();
    expect(find.text('New failure'), findsOneWidget);
    expect(find.text('HTTP response headers timed out'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('conversation renders Markdown, message times, turn duration, and copies original content', (tester) async {
    final started = DateTime(2026, 10, 31, 9, 41);
    const response = '''## Ready for review

The **conversation** supports _formatted answers_ and [project links](https://example.com).

- Clear messages
- Nested details
  - Kept in order

> A useful note.

- [x] Render Markdown
- [ ] Ship the release

| Feature | Status |
| --- | --- |
| Messages | Ready |
| Images | Ready |

```dart
final message = 'Hello';
print(message);
```
''';
    final task = DesktopTask('markdown', 'Conversation')..events.addAll({
      1: {'seq': 1, 'type': 'turn.started', 'created_at': started.toUtc().toIso8601String(), 'data': {}},
      2: {'seq': 2, 'type': 'input.committed', 'created_at': started.toUtc().toIso8601String(), 'data': {'item': {
        'role': 'user', 'content': [{'type': 'text', 'text': 'Plan the release'}],
      }}},
      3: {'seq': 3, 'type': 'model.completed', 'created_at': started.add(const Duration(seconds: 84)).toUtc().toIso8601String(), 'data': {'output': [
        {'content': [{'type': 'text', 'text': response}]},
      ]}},
      4: {'seq': 4, 'type': 'turn.completed', 'created_at': started.add(const Duration(seconds: 85)).toUtc().toIso8601String(), 'data': {}},
    });
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester, task);
    await tester.pumpAndSettle();
    final heading = find.text('Ready for review', findRichText: true);
    expect(heading, findsOneWidget);
    expect(find.textContaining('## Ready for review'), findsNothing);
    expect(find.byType(Table), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outlined), findsOneWidget);
    expect(find.textContaining('09:41'), findsOneWidget);
    expect(find.text('1m 25s'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Plan the release', findRichText: true)).dx,
      greaterThan(tester.getTopLeft(heading).dx + 100));

    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(clipboard, "final message = 'Hello';\nprint(message);\n");
    await tester.tap(find.byTooltip('Wrap long lines'));
    await tester.pump();
    expect(find.byTooltip('Scroll long lines'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(heading));
    await tester.pump();
    await tester.tap(find.byTooltip('Copy response'));
    await tester.pump();
    expect(clipboard, response);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compaction replaces working progress and retains one timed summary row on replay', (tester) async {
    final started = DateTime.now().subtract(const Duration(seconds: 45));
    final task = DesktopTask('compact', 'Compaction')
      ..running = true
      ..streamingText = 'Internal compaction text'
      ..events.addAll({
        1: {'seq': 1, 'type': 'turn.started', 'created_at': started.subtract(const Duration(minutes: 2)).toIso8601String(), 'data': {}},
        2: {'id': 'compaction', 'seq': 2, 'type': 'compaction.started', 'created_at': started.toIso8601String(), 'data': {'reason': 'threshold'}},
      });
    await open(tester, task, size: const Size(420, 800));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Compacting context'), findsNWidgets(2));
    expect(find.textContaining('Working'), findsNothing);
    expect(find.text('Internal compaction text', findRichText: true), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    task.retryStatus = 'Reconnecting… 1/5';
    await open(tester, task, size: const Size(420, 800));
    await tester.pump();
    expect(find.textContaining('Compacting context · Reconnecting… 1/5'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    task
      ..streamingText = ''
      ..retryStatus = null
      ..events[3] = {'seq': 3, 'type': 'context.compacted', 'created_at': started.add(const Duration(seconds: 42)).toIso8601String(), 'data': {
        'summary': 'Keep the **release plan**.',
        'input': [{'kind': 'compaction', 'native': {'encrypted_content': 'private-provider-state'}}],
      }};
    await open(tester, task, size: const Size(420, 800));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.text('Working'), findsNWidgets(2));
    expect(find.textContaining('Compacting context'), findsNothing);
    expect(find.text('Keep the release plan.', findRichText: true), findsNothing);
    await tester.tap(find.text('Context compacted'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Keep the release plan.', findRichText: true), findsOneWidget);
    expect(find.textContaining('private-provider-state'), findsNothing);
    expect(conversation(task).where((entry) => entry.compaction != null).single.compaction!.endedAt!.millisecondsSinceEpoch,
      started.add(const Duration(seconds: 42)).millisecondsSinceEpoch);
    task
      ..running = false
      ..events[4] = {'seq': 4, 'type': 'turn.completed', 'data': {}};
    final replayed = DesktopTask(task.id, task.title)
      ..events.addEntries(task.events.entries.toList().reversed);
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester, replayed);
    await tester.pumpAndSettle();
    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed, stopped, and interrupted compactions settle without claiming success', (tester) async {
    for (final (terminal, label) in [
      ('turn.failed', 'Compaction failed'),
      ('turn.cancelled', 'Compaction stopped'),
      ('turn.completed', 'Compaction interrupted'),
    ]) {
      final task = DesktopTask(terminal, 'Compaction')..events.addAll({
        2: {'seq': 2, 'type': 'compaction.started', 'data': {}},
        3: {'seq': 3, 'type': terminal, 'data': {'error': 'Provider failed'}},
        4: {'seq': 4, 'type': 'turn.started', 'data': {}},
        5: {'seq': 5, 'type': 'compaction.started', 'data': {}},
        6: {'seq': 6, 'type': 'context.compacted', 'data': {}},
      });
      await open(tester, task);
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      expect(find.text('Context compacted'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    final incomplete = DesktopTask('incomplete', 'Compaction')..events[1] = {
      'seq': 1, 'type': 'compaction.started', 'data': {},
    };
    await open(tester, incomplete);
    await tester.pumpAndSettle();
    expect(find.text('Compaction interrupted'), findsOneWidget);
    final legacy = DesktopTask('legacy', 'Compaction')..events[1] = {
      'seq': 1, 'type': 'context.compacted', 'data': {'summary': ''},
    };
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester, legacy);
    await tester.pumpAndSettle();
    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.textContaining(' in '), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('images decode from inline data and relative files, open a preview, and fail gracefully', (tester) async {
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('conversation-images-');
      await File('${directory.path}/local image.png').writeAsBytes(base64Decode(_png));
    });
    addTearDown(() => directory.delete(recursive: true));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: ConversationMarkdown(directory: directory.path, text:
          '![Inline preview](data:image/png;base64,$_png)\n\n![Local preview](local%20image.png)\n\n![Missing preview](missing.png)'),
      ))));
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(image.image, tester.element(find.byType(Scaffold)), onError: (_, _) {});
      }
    });
    await tester.pumpAndSettle();
    expect(tester.widgetList<RawImage>(find.byType(RawImage)).where((image) => image.image != null).length, 2);
    expect(find.text('Could not load image'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Open image').first);
      await tester.pump();
      final preview = tester.widget<ImagePreview>(find.byType(ImagePreview));
      await precacheImage(preview.images[preview.initialIndex].provider, tester.element(find.byType(Scaffold).first));
    });
    await tester.pumpAndSettle();
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close image'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Zoom in'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('conversation reuses unchanged records and invalidates replay and live state', () {
    final task = DesktopTask('cache', 'Projection cache')..running = true;
    Map<String, dynamic> answer(String text) => {'seq': 1, 'type': 'model.completed', 'data': {'output': [
      {'content': [{'type': 'text', 'text': text}]},
    ]}};
    task.events[1] = answer('First');
    final first = conversation(task);
    expect(identical(conversation(task), first), isTrue);
    task.events[1] = answer('Replayed');
    expect(conversation(task).single.text, 'Replayed');
    expect(identical(conversation(task), first), isFalse);
    task.streamingText = 'Partial';
    expect(conversation(task).last.text, 'Partial');
    task.pending['pending'] = {'id': 'pending', 'delivery': 'queue', 'prompt': 'Queued'};
    expect(conversation(task).last.text, 'Queued');
    task.pending['pending'] = {'id': 'pending', 'delivery': 'queue', 'prompt': 'Replaced'};
    expect(conversation(task).last.text, 'Replaced');
    task.pending.clear();
    task.streamingText = '';
    applySessionEvent(task.messages, {'id': 'evt_stop', 'type': 'session.execution.interrupted', 'data': {}, 'created': 1}, {});
    expect(conversation(task).last.text, 'Stopped');
    task.events.clear();
    task.messages.clear();
    expect(conversation(task), isEmpty);
  });

  testWidgets('long conversations show the newest rows in the first frame', (tester) async {
    final task = DesktopTask('long', 'Long conversation');
    for (var i = 1; i <= 500; i++) {
      task.events[i] = {'seq': i, 'type': 'model.completed', 'data': {'output': [
        {'content': [{'type': 'text', 'text': 'Answer $i\n\n${List.filled(4, 'A paragraph with enough detail to wrap across lines.').join('\n\n')}'}]},
      ]}};
    }
    await open(tester, task, size: const Size(800, 650));
    expect(find.textContaining('Answer 500', findRichText: true).hitTestable(), findsOneWidget);
    expect(find.textContaining('Answer 1\n', findRichText: true), findsNothing);
    expect(find.byType(ConversationMarkdown).evaluate().length, lessThan(12));
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.extentBefore, 0);
    await tester.pump();
    expect(position.pixels, 0, reason: 'Opening at the end needs no corrective scrolling');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('collapsed tools defer JSON formatting until their contents are opened', (tester) async {
    final arguments = _CountedJson({'cmd': 'pwd'});
    final output = _CountedJson({'output': '/project'});
    final task = DesktopTask('lazy-tools', 'Lazy tools')..messages['msg_tools'] = {
      'id': 'msg_tools', 'type': 'assistant', 'metadata': {'seq': 1}, 'time': {'created': 1, 'streamed': 2}, 'content': [
        {'type': 'tool', 'id': 'cell', 'name': 'functions.exec', 'time': {'created': 1},
          'state': {'status': 'completed', 'input': {'code': 'text(await tools.exec_command({cmd: "pwd"}));'}}},
        {'type': 'tool', 'id': 'shell', 'name': 'exec_command', 'time': {'created': 1}, 'native': {'parentCallID': 'cell'},
          'state': {'status': 'completed', 'input': arguments, 'content': [{'type': 'text', 'text': output}]}},
      ],
    };
    await open(tester, task);
    expect(arguments.encodes, 0);
    expect(output.encodes, 0);
    await tester.tap(find.textContaining('Used 1', findRichText: true));
    await tester.pumpAndSettle();
    expect(arguments.encodes, 0);
    expect(output.encodes, 0);
    await tester.tap(find.text('exec_command'));
    await tester.pumpAndSettle();
    expect(arguments.encodes, 1);
    expect(output.encodes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('new output follows the end but does not pull readers away from older messages', (tester) async {
    final task = DesktopTask('scroll', 'Long conversation');
    void addMessage(int sequence, String text) {
      task.events[sequence] = {'seq': sequence, 'type': 'model.completed', 'data': {'output': [
        {'content': [{'type': 'text', 'text': text}]},
      ]}};
    }
    for (var index = 1; index <= 30; index++) {
      addMessage(index, 'Message $index\n\n${List.filled(index % 4 + 1, 'A paragraph with enough detail to make each row a different height.').join('\n\n')}');
    }
    await open(tester, task, size: const Size(800, 650));
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.extentBefore, lessThan(1));
    await tester.drag(find.byType(ListView), const Offset(0, 550));
    await tester.pumpAndSettle();
    final readingOffset = position.pixels;
    expect(position.extentBefore, greaterThan(100));
    addMessage(31, 'The latest answer');
    await open(tester, task, size: const Size(800, 650));
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(readingOffset, 1));
    await tester.tap(find.text('Jump to latest'));
    await tester.pumpAndSettle();
    expect(position.extentBefore, lessThan(1));
    expect(find.text('The latest answer', findRichText: true).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('generated images stay in their reply and reuse decoded pixels after scrolling', (tester) async {
    late String data;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1200, 1800);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      data = base64Encode(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
    final image = {'type': 'image', 'name': 'Generated image', 'mime_type': 'image/png', 'data': data};
    final task = DesktopTask('tool-image', 'Generated image')..loaded = true;
    for (var index = 0; index < 20; index++) {
      task.messages['user$index'] = {'id': 'user$index', 'type': 'user', 'metadata': {'seq': index},
        'time': {'created': index}, 'text': List.filled(5, 'Earlier message $index').join('\n\n')};
    }
    task.messages['tools'] = {'id': 'tools', 'type': 'assistant', 'metadata': {'seq': 20},
      'time': {'created': 20, 'streamed': 21}, 'content': [
        {'type': 'text', 'text': 'Generating the image'},
        {'type': 'tool', 'id': 'cell', 'name': 'functions.exec', 'time': {'created': 20},
          'state': {'status': 'completed', 'input': {'code': 'await tools.imagegen()'}, 'content': [image]}},
        {'type': 'tool', 'id': 'image', 'name': 'image_gen.imagegen', 'time': {'created': 20},
          'native': {'parentCallID': 'cell'}, 'state': {'status': 'completed', 'input': {}, 'content': [
            {'type': 'text', 'text': jsonEncode([{'type': 'input_image', 'image_url': 'data:image/png;base64,$data'}])},
            image,
          ]}},
        {'type': 'text', 'text': 'Scan this image'},
      ]};
    task.messages['follow-up'] = {'id': 'follow-up', 'type': 'user', 'metadata': {'seq': 21},
      'time': {'created': 18}, 'text': 'invalid qr code. next'};
    task.messages['answer'] = {'id': 'answer', 'type': 'assistant', 'metadata': {'seq': 22},
      'time': {'created': 22, 'streamed': 23}, 'content': [{'type': 'text', 'text': 'Done'}]};
    task.messages['idle'] = {'id': 'idle', 'type': 'idle', 'metadata': {'seq': 23},
      'time': {'created': 23}, 'outcome': 'succeeded'};
    await tester.runAsync(() async {
      await open(tester, task, size: const Size(800, 650));
      expect(find.byType(ConversationImage), findsOneWidget);
      await precacheImage(tester.widget<Image>(find.byType(Image)).image, tester.element(find.byType(Scaffold)));
    });
    await tester.pumpAndSettle();
    final decoded = tester.widget<RawImage>(find.byType(RawImage)).image!.clone();
    addTearDown(decoded.dispose);
    expect(decoded.height, lessThanOrEqualTo(390));
    expect(tester.getSize(find.byType(ConversationImage)).height, lessThanOrEqualTo(390));
    expect(tester.getBottomLeft(find.byType(ConversationImage)).dy,
      lessThan(tester.getTopLeft(find.text('Scan this image', findRichText: true)).dy));
    expect(tester.getBottomLeft(find.byType(ConversationImage)).dy,
      lessThan(tester.getTopLeft(find.text('invalid qr code. next', findRichText: true)).dy));
    expect(find.byType(ConversationImage).hitTestable(), findsOneWidget);
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.extentBefore, 0);
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationImage), findsNothing);
    await tester.tap(find.text('Jump to latest'));
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.isCloneOf(decoded), isTrue,
      reason: 'Returning to a generated image must reuse its decoded pixels');
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Open image'));
      await tester.pump();
      final preview = tester.widget<ImagePreview>(find.byType(ImagePreview));
      await precacheImage(preview.images.single.provider, tester.element(find.byType(Scaffold).first));
    });
    await tester.pumpAndSettle();
    final full = tester.widget<RawImage>(find.descendant(of: find.byType(ImagePreview), matching: find.byType(RawImage))).image!;
    expect(full.width, 1200);
    expect(full.height, 1800);
    await tester.tap(find.byTooltip('Close image'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());

    final completed = DesktopTask('completed-image', 'Completed generation')..loaded = true
      ..messages.addAll({...task.messages}..remove('follow-up'));
    await tester.runAsync(() async {
      await open(tester, completed, size: const Size(800, 650));
      await precacheImage(tester.widget<Image>(find.byType(Image)).image, tester.element(find.byType(Scaffold)));
    });
    await tester.pumpAndSettle();
    expect(find.byType(ConversationImage), findsOneWidget);
    expect(tester.getTopLeft(find.byType(ConversationImage)).dy,
      greaterThan(tester.getTopLeft(find.text('Done', findRichText: true)).dy));
    expect(find.byType(ConversationImage).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('narrow conversations handle wide code and tables while streaming incomplete Markdown', (tester) async {
    final started = DateTime.now().subtract(const Duration(seconds: 25));
    final task = DesktopTask('stream', 'Streaming')
      ..running = true
      ..events[1] = {'seq': 1, 'type': 'turn.started', 'created_at': started.toUtc().toIso8601String(), 'data': {}}
      ..streamingText = '''## In progress

| Long column name | Another long column | Third column | Fourth column |
| --- | --- | --- | --- |
| Some text | More text | An entry | Last entry |

```javascript
const value = "${List.filled(100, 'long').join()}";
''';
    await open(tester, task, size: const Size(420, 800));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('In progress', findRichText: true), findsOneWidget);
    expect(find.text('Working'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    final completed = '${task.streamingText}\n```\n\n**Done.**';
    task
      ..streamingText = ''
      ..running = false
      ..events[2] = {'seq': 2, 'type': 'model.completed', 'data': {'output': [
        {'content': [{'type': 'text', 'text': completed}]},
      ]}}
      ..events[3] = {'seq': 3, 'type': 'turn.completed', 'created_at': started.add(const Duration(seconds: 25)).toUtc().toIso8601String(), 'data': {}};
    await open(tester, task, size: const Size(420, 800));
    await tester.pumpAndSettle();
    expect(find.text('Done.', findRichText: true), findsOneWidget);
    expect(find.text('Working'), findsNothing);
    expect(conversation(task).where((entry) => entry.response != null).single.response!.duration, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _CountedJson {
  _CountedJson(this.value);
  final Map<String, Object?> value;
  int encodes = 0;
  Map<String, Object?> toJson() {
    encodes++;
    return value;
  }
}
