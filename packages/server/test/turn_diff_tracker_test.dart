// Codex core/src/turn_diff_tracker_tests.rs, ddd1812a5.
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/src/turn_diff_tracker.dart';
import 'package:test/test.dart';
import 'package:tool_runtime/tool_runtime.dart';

void main() {
  late Directory root;
  late CancellationToken cancellation;
  late TurnDiffTracker tracker;
  Future<void> apply(String body) => applyPatch(root.path, '*** Begin Patch\n$body\n*** End Patch',
    cancellation: cancellation, onPatch: (delta) async { tracker.trackDelta(delta); });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('turn-diff-');
    cancellation = CancellationToken();
    tracker = TurnDiffTracker(displayRoots: {'': root.path});
  });
  tearDown(() async { cancellation.cancel(); await root.delete(recursive: true); });

  group('committed turn diffs', () {
    test('accumulates add then update as a single add with Git blob ids', () async {
      await apply('*** Add File: a.txt\n+foo');
      await apply('*** Update File: a.txt\n@@\n foo\n+bar');
      expect(tracker.unifiedDiffText, '''
diff --git a/a.txt b/a.txt
new file mode 100644
index 0000000000000000000000000000000000000000..3bd1f0e29744a1f32b08d5650e62e2e62afb177c
--- /dev/null
+++ b/a.txt
@@ -0,0 +1,2 @@
+foo
+bar
''');
    });

    test('tracks deletion using the committed content after the file is gone', () async {
      await File('${root.path}/b.txt').writeAsString('x\n');
      await apply('*** Delete File: b.txt');
      expect(tracker.unifiedDiffText, contains('deleted file mode 100644\n'));
      expect(tracker.unifiedDiffText, contains('--- a/b.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n'));
      expect(await File('${root.path}/b.txt').exists(), false);
    });

    for (final scenario in ['move and update', 'pure rename', 'add over existing', 'delete then readd',
        'move over unchanged destination', 'move over changed destination', 'delete destination then move']) {
      test(scenario, () async {
        await File('${root.path}/src.txt').writeAsString('before\n');
        if (scenario.contains('destination')) await File('${root.path}/dst.txt').writeAsString('destination\n');
        switch (scenario) {
          case 'move and update':
            await apply('*** Update File: src.txt\n*** Move to: dst.txt\n@@\n-before\n+after');
            expect(tracker.unifiedDiffText, contains('diff --git a/src.txt b/dst.txt\n'));
            expect(tracker.unifiedDiffText, contains('-before\n+after\n'));
          case 'pure rename':
            await apply('*** Update File: src.txt\n*** Move to: dst.txt\n@@\n before');
            expect(tracker.unifiedDiffText, isNull);
            expect(await File('${root.path}/dst.txt').readAsString(), 'before\n');
          case 'add over existing':
            await apply('*** Add File: src.txt\n+after');
            expect(tracker.unifiedDiffText, isNot(contains('new file mode')));
            expect(tracker.unifiedDiffText, contains('-before\n+after\n'));
          case 'delete then readd':
            await apply('*** Delete File: src.txt');
            await apply('*** Add File: src.txt\n+after');
            expect(tracker.unifiedDiffText, isNot(contains('file mode')));
            expect(tracker.unifiedDiffText, contains('-before\n+after\n'));
          case 'move over unchanged destination':
            await apply('*** Update File: src.txt\n*** Move to: dst.txt\n@@\n-before\n+destination');
            expect(tracker.unifiedDiffText, contains('diff --git a/src.txt b/src.txt\n'));
            expect(tracker.unifiedDiffText, isNot(contains('b/dst.txt')));
          case 'move over changed destination':
            await apply('*** Update File: src.txt\n*** Move to: dst.txt\n@@\n-before\n+after');
            expect(tracker.unifiedDiffText, contains('diff --git a/src.txt b/src.txt\n'));
            expect(tracker.unifiedDiffText, contains('diff --git a/dst.txt b/dst.txt\n'));
            expect(tracker.unifiedDiffText, contains('-destination\n+after\n'));
          case 'delete destination then move':
            await apply('*** Delete File: dst.txt\n*** Update File: src.txt\n*** Move to: dst.txt\n@@\n-before\n+after');
            expect(tracker.unifiedDiffText, contains('-destination\n+after\n'));
            expect(tracker.unifiedDiffText, contains('deleted file mode 100644'));
        }
      });
    }

    test('reverting an edit and adding then deleting produce no net diff', () async {
      await File('${root.path}/a.txt').writeAsString('before\n');
      await apply('*** Update File: a.txt\n@@\n-before\n+after');
      await apply('*** Update File: a.txt\n@@\n-after\n+before');
      await apply('*** Add File: temporary.txt\n+temporary');
      await apply('*** Delete File: temporary.txt');
      expect(tracker.unifiedDiffText, isNull);
    });

    test('inexact mutations invalidate previous and future diffs', () async {
      await apply('*** Add File: a.txt\n+first');
      expect(tracker.unifiedDiffText, isNotNull);
      tracker.trackDelta({'exact': false, 'changes': []});
      await apply('*** Add File: b.txt\n+second');
      expect(tracker.unifiedDiffText, isNull);
    });

    test('a later preparation failure retains the successfully committed prefix', () async {
      await File('${root.path}/blocked').writeAsString('not a directory');
      await expectLater(apply('*** Add File: a.txt\n+committed\n*** Add File: blocked/b.txt\n+never written'),
        throwsA(isA<FileSystemException>()));
      expect(tracker.unifiedDiffText, contains('+committed\n'));
      expect(tracker.unifiedDiffText, isNot(contains('b.txt')));
    });

    test('separates the same path across environments and displays foreign roots', () {
      tracker = TurnDiffTracker(displayRoots: {'local': '/workspace', 'remote': r'C:\workspace'});
      tracker.trackDelta({'exact': true, 'changes': [
        {'type': 'A', 'path': '/workspace/shared.txt', 'newContent': 'local\n'},
      ]}, environment: 'local');
      tracker.trackDelta({'exact': true, 'changes': [
        {'type': 'A', 'path': r'C:\workspace\shared.txt', 'newContent': 'remote\n'},
      ]}, environment: 'remote');
      expect(tracker.unifiedDiffText, contains('diff --git a/local/shared.txt b/local/shared.txt\n'));
      expect(tracker.unifiedDiffText, contains('diff --git a/remote/shared.txt b/remote/shared.txt\n'));
    });

    test('preserves distant context, CRLF and missing final newlines in an applicable diff', () async {
      final before = '${List.generate(24, (i) => 'line $i\r\n').join()}last';
      final after = before.replaceFirst('line 2\r\n', 'changed 2\r\n').replaceFirst('line 20\r\n', 'changed 20\r\n');
      await File('${root.path}/a.txt').writeAsString(before);
      tracker.trackDelta({'exact': true, 'changes': [
        {'type': 'M', 'path': '${root.path}/a.txt', 'oldContent': before, 'newContent': after},
      ]});
      final patch = File('${root.path}/change.diff');
      await patch.writeAsString(tracker.unifiedDiffText!);
      final applied = await Process.run('git', ['apply', '--no-index', patch.path], workingDirectory: root.path);
      expect(applied.exitCode, 0, reason: '${applied.stderr}');
      expect(await File('${root.path}/a.txt').readAsString(), after);
    });

    test('large rewrites return promptly and preserve exact replacement content', () async {
      final before = List.generate(10000, (i) => 'old $i\n').join();
      final after = List.generate(10000, (i) => 'new $i\n').join();
      await File('${root.path}/large.txt').writeAsString(before);
      final watch = Stopwatch()..start();
      tracker.trackDelta({'exact': true, 'changes': [
        {'type': 'M', 'path': '${root.path}/large.txt', 'oldContent': before, 'newContent': after},
      ]});
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      final patch = File('${root.path}/change.diff');
      await patch.writeAsString(tracker.unifiedDiffText!);
      final applied = await Process.run('git', ['apply', '--no-index', patch.path], workingDirectory: root.path);
      expect(applied.exitCode, 0, reason: '${applied.stderr}');
      expect(await File('${root.path}/large.txt').readAsString(), after);
    });
  });
}
