import 'package:desktop/appearance.dart';
import 'package:desktop/conversation.dart';
import 'package:desktop/conversation_changes.dart';
import 'package:desktop/diff_viewer.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('conversation file changes', () {
    testWidgets('finished steered turn exposes one file tree after its last response and opens the selected diff', (tester) async {
      tester.view.physicalSize = const Size(1000, 1000); tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
      const diff = '''diff --git a/lib/app.dart b/lib/app.dart
index before..after
--- a/lib/app.dart
+++ b/lib/app.dart
@@ -1,2 +1,3 @@
-old value
+new value
+++ header-looking content
 unchanged value
diff --git a/lib/old.dart b/lib/old.dart
deleted file mode 100644
--- a/lib/old.dart
+++ /dev/null
@@ -1 +0,0 @@
-deleted value
''';
      final task = DesktopTask('thread', 'File changes')..loaded = true;
      task.turns['turn'] = {'id': 'turn', 'status': 'completed', 'diff': diff};
      task.messages.addAll({
        'progress': {'id': 'progress', 'type': 'agentMessage', 'turnId': 'turn', 'phase': 'commentary', 'order': 0,
          'text': 'Updating the application.'},
        'steer': {'id': 'steer', 'type': 'userMessage', 'turnId': 'turn', 'order': 1,
          'content': [{'type': 'text', 'text': 'Also remove the old file.'}]},
        'patch': {'id': 'patch', 'type': 'fileChange', 'turnId': 'turn', 'status': 'completed', 'order': 2,
          'changes': [
            {'path': '/project/lib/app.dart', 'kind': {'type': 'update'}, 'diff': '@@ -1,2 +1,3 @@\n-old value\n+new value\n+++ header-looking content\n unchanged value\n'},
            {'path': '/project/lib/old.dart', 'kind': {'type': 'delete'}, 'diff': 'deleted value\n'},
          ]},
        'answer': {'id': 'answer', 'type': 'agentMessage', 'turnId': 'turn', 'phase': 'final_answer', 'order': 3,
          'text': 'Updated the application.'},
      });
      String? openedSource, openedPath;
      await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: Scaffold(
        body: ConversationDiffScope(onOpen: (source, path) { openedSource = source; openedPath = path; },
          child: ConversationTranscript(task: task, directory: '/project', onRetry: () {})))));
      await tester.pumpAndSettle();
      expect(find.text('2 changed files'), findsOneWidget);
      expect(tester.getTopLeft(find.text('2 changed files')).dy,
        greaterThan(tester.getBottomLeft(find.text('Updated the application.', findRichText: true)).dy));
      expect(find.text('Worked'), findsNWidgets(2));
      await tester.tap(find.text('Worked').first); await tester.pumpAndSettle();
      expect(find.text('Updating the application.', findRichText: true), findsOneWidget);
      expect(find.text('2 changed files'), findsOneWidget);
      expect(find.text('app.dart'), findsNothing);
      expect(find.text('+2'), findsWidgets);
      expect(find.text('−2'), findsWidgets);
      await tester.tap(find.byTooltip('Expand all folders')); await tester.pumpAndSettle();
      await tester.tap(find.text('app.dart')); await tester.pumpAndSettle();
      expect(openedSource, 'turn:turn'); expect(openedPath, 'lib/app.dart');

      final files = changesForSource(task, openedSource!);
      await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: Scaffold(
        body: DiffViewer(files: files, selectedPath: openedPath, directory: '/project'))));
      await tester.pumpAndSettle();
      expect(find.text('old value'), findsOneWidget); expect(find.text('new value'), findsOneWidget);
      expect(find.text('++ header-looking content'), findsOneWidget);
      await tester.tap(find.byTooltip('Split diff')); await tester.pumpAndSettle();
      expect(find.text('old value'), findsOneWidget); expect(find.text('new value'), findsOneWidget);
      expect(find.byTooltip('Unified diff'), findsOneWidget);
      expect(find.text('2'), findsNWidgets(2)); expect(find.text('3'), findsOneWidget);
      await tester.tap(find.byTooltip('Next file')); await tester.pumpAndSettle();
      expect(find.text('deleted value'), findsOneWidget);
      expect(find.byTooltip('Open file'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
