import 'dart:convert';
import 'dart:io';

import 'package:desktop/conversation.dart';
import 'package:desktop/conversation_markdown.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';

void main() {
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
    expect(find.text('Completed in 1m 25s'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Plan the release', findRichText: true)).dx,
      greaterThan(tester.getTopLeft(heading).dx + 100));

    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(clipboard, "final message = 'Hello';\nprint(message);\n");
    await tester.tap(find.byTooltip('Wrap long lines'));
    await tester.pump();
    expect(find.byTooltip('Scroll long lines'), findsOneWidget);
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
    expect(find.textContaining('Compacting context ·'), findsOneWidget);
    expect(find.textContaining('Working'), findsNothing);
    expect(find.text('Internal compaction text', findRichText: true), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    task.retryStatus = 'Reconnecting… 1/5';
    await open(tester, task, size: const Size(420, 800));
    await tester.pump();
    expect(find.textContaining('Compacting context · Reconnecting… 1/5'), findsOneWidget);
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
    expect(find.text('Context compacted in 42s'), findsOneWidget);
    expect(find.textContaining('Working ·'), findsOneWidget);
    expect(find.textContaining('Compacting context'), findsNothing);
    expect(find.text('Keep the release plan.', findRichText: true), findsNothing);
    await tester.tap(find.text('Context compacted in 42s'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Keep the release plan.', findRichText: true), findsOneWidget);
    expect(find.textContaining('private-provider-state'), findsNothing);
    expect(conversation(task).where((entry) => entry.compaction != null).single.id, 'compaction');
    task
      ..running = false
      ..events[4] = {'seq': 4, 'type': 'turn.completed', 'data': {}};
    final replayed = DesktopTask(task.id, task.title)
      ..events.addEntries(task.events.entries.toList().reversed);
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester, replayed);
    await tester.pumpAndSettle();
    expect(find.text('Context compacted in 42s'), findsOneWidget);
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
    await tester.tap(find.byTooltip('Open image').first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Close image'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
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
    expect(position.extentAfter, lessThan(1));
    await tester.drag(find.byType(ListView), const Offset(0, 550));
    await tester.pumpAndSettle();
    final readingOffset = position.pixels;
    expect(position.extentAfter, greaterThan(100));
    addMessage(31, 'The latest answer');
    await open(tester, task, size: const Size(800, 650));
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(readingOffset, 1));
    await tester.tap(find.text('Jump to latest'));
    await tester.pumpAndSettle();
    expect(position.extentAfter, lessThan(1));
    expect(find.text('The latest answer', findRichText: true).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('MCP tool images remain visible inside the tool disclosure', (tester) async {
    final task = DesktopTask('tool-image', 'Screenshot')..events.addAll({
      1: {'seq': 1, 'type': 'tool.started', 'data': {'call_id': 'image', 'name': 'screenshot', 'namespace': 'mcp__browser', 'input': '{}'}},
      2: {'seq': 2, 'type': 'tool.completed', 'data': {'item': {'content': [
        {'call_id': 'image', 'output': jsonEncode({'output': {'content': [
          {'type': 'image', 'data': _png, 'mimeType': 'image/png'},
        ]}})},
      ]}}},
    });
    await open(tester, task);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.text('mcp__browser.screenshot'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await precacheImage(tester.widget<Image>(find.byType(Image)).image, tester.element(find.byType(Scaffold)));
    });
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.text('Code & output'), findsOneWidget);
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
    expect(find.textContaining('Working ·'), findsOneWidget);
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
    expect(find.textContaining('Working ·'), findsNothing);
    expect(find.text('Completed in 25s'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
