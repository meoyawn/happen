// Modified Dart port of Codex apply-patch tests, 0598a96e9361485f.
// Copyright 2025 OpenAI, Apache-2.0. See packages/openai/tools/CODEX-LICENSE.
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:test/test.dart';
import 'package:tool_runtime/tool_runtime.dart';

void main() {
  late Directory root;
  late CancellationToken cancellation;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('apply-patch-');
    cancellation = TimeoutCancellationToken(const Duration(seconds: 15));
  });
  tearDown(() async {
    cancellation.cancel();
    await root.delete(recursive: true);
  });
  Future<String> apply(String body, {Future<void> Function(Json)? onPatch}) =>
    applyPatch(root.path, '*** Begin Patch\n$body\n*** End Patch', cancellation: cancellation, onPatch: onPatch);

  final scenarios = Directory('test/fixtures/apply_patch').listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final scenario in scenarios) {
    final name = scenario.uri.pathSegments.where((part) => part.isNotEmpty).last;
    test('Codex scenario $name', () async {
      await _copy(Directory('${scenario.path}/input'), root);
      final patch = await File('${scenario.path}/patch.txt').readAsString();
      Object? failure;
      try { await applyPatch(root.path, patch, cancellation: cancellation); }
      catch (error) { failure = error; }
      final shouldFail = {'005', '006', '007', '008', '009', '012', '013', '015'}.contains(name.substring(0, 3));
      expect(failure, shouldFail ? isNotNull : isNull, reason: '$failure');
      expect(await _snapshot(root), await _snapshot(Directory('${scenario.path}/expected')));
    });
  }

  for (final (name, original, body, expected) in <(String, String, String, String)>[
    ('CR only', 'one\rtwo\rthree\r', '@@\n-one\n+uno\n@@\n two\n+\n+between\n three', 'uno\rtwo\r\rbetween\rthree\r'),
    ('append after blank CRLF', 'a\r\n\r\n', '@@\n+new', 'a\r\n\r\nnew\r\n'),
    ('mixed repeated context', 'same\r\nsame\n', '@@\n-same\n same', 'same\n'),
    ('repeated replacement order', 'a\nb\n', '@@\n-a\n-b\n+b\n+b\n+a', 'b\nb\na\n'),
    ('missing CRLF terminator', 'one\r\ntwo', '@@\n-one\n+ONE', 'ONE\r\ntwo\r\n'),
    ('deleting all lines', 'one\n', '@@\n-one', ''),
    ('empty file pure insertion', '', '@@\n+new', 'new\n'),
    ('pure insertion before removal', 'line1\nline2\nline3\n', '@@\n+after-context\n+second-line\n@@\n line1\n-line2\n-line3\n+line2-replacement', 'line1\nline2-replacement\nafter-context\nsecond-line\n'),
    ('first chunk without marker', 'import foo\n', ' import foo\n+bar', 'import foo\nbar\n'),
    ('bare blank context', 'before\n\nafter\n', '@@\n before\n\n-after\n+AFTER', 'before\n\nAFTER\n'),
    ('indented patch marker is context', 'old a\n*** Update File: b.txt\nold b\n', '@@\n-old a\n+new a\n *** Update File: b.txt\n@@\n-old b\n+new b', 'new a\n*** Update File: b.txt\nnew b\n'),
    ('blank lines after EOF marker', 'foo\n', '@@\n+quux\n*** End of File\n\n', 'foo\nquux\n'),
    ('trailing newline sentinel', 'foo\nbar\nbaz\n', '@@\n foo\n bar\n-baz\n+BAZ\n ', 'foo\nbar\nBAZ\n'),
    ('trailing whitespace fallback', 'foo  \nbar\t\n', '@@\n-foo\n-bar\n+changed', 'changed\n'),
    ('leading whitespace fallback', '    foo  \n   bar\t\n', '@@\n-foo\n-bar\n+changed', 'changed\n'),
    ('exact match beats earlier fuzzy match', 'foo  \nfoo\n', '@@\n-foo\n+changed', 'foo  \nchanged\n'),
    ('trailing fallback beats full trim', ' foo\nfoo  \n', '@@\n-foo\n+changed', ' foo\nchanged\n'),
    ('Unicode punctuation fallback', 'import asyncio  # local import – avoids top‑level dep\n', '@@\n-import asyncio  # local import - avoids top-level dep\n+import asyncio  # HELLO', 'import asyncio  # HELLO\n'),
    ('Unicode quotes and spaces', '“hello”\u00a0‘world’\u2212done\n', '@@\n-"hello" \'world\'-done\n+changed', 'changed\n'),
    ('fuzzy context remains unchanged', '  “header”  \nold\n', '@@\n "header"\n-old\n+new', '  “header”  \nnew\n'),
    ('fuzzy skip-ahead marker', '  def f():  \nold\n', '@@ def f():\n-old\n+new', '  def f():  \nnew\n'),
    ('EOF chooses final occurrence', 'same\nmiddle\nsame\n', '@@\n-same\n+last\n*** End of File', 'same\nmiddle\nlast\n'),
  ]) {
    test('Codex update $name', () async {
      final target = File('${root.path}/file.txt');
      await target.writeAsString(original);
      final summary = await apply('*** Update File: file.txt\n$body');
      expect(await target.readAsBytes(), utf8.encode(expected));
      expect(summary, 'Success. Updated the following files:\nM file.txt\n');
    });
  }

  test('Codex summary groups operations and preserves supplied path spelling', () async {
    await File('${root.path}/modify.txt').writeAsString('line1\nline2\n');
    await File('${root.path}/delete.txt').writeAsString('obsolete\n');
    expect(await apply('*** Add File: nested/new.txt\n+created\n*** Delete File: delete.txt\n*** Update File: modify.txt\n@@\n-line2\n+changed'),
      'Success. Updated the following files:\nA nested/new.txt\nM modify.txt\nD delete.txt\n');
    expect(await File('${root.path}/nested/new.txt').readAsString(), 'created\n');
    expect(await File('${root.path}/modify.txt').readAsString(), 'line1\nchanged\n');
    expect(await File('${root.path}/delete.txt').exists(), isFalse);
  });

  for (final absolute in [false, true]) {
    test('Codex relative and absolute paths: absolute=$absolute', () async {
      final prefix = absolute ? '${root.path}/' : '';
      await File('${root.path}/delete.txt').writeAsString('delete\n');
      await File('${root.path}/update.txt').writeAsString('old\n');
      final summary = await apply('*** Add File: ${prefix}add.txt\n+created\n*** Delete File: ${prefix}delete.txt\n*** Update File: ${prefix}update.txt\n*** Move to: ${prefix}moved/file.txt\n@@\n-old\n+new');
      expect(summary, 'Success. Updated the following files:\nA ${prefix}add.txt\nM ${prefix}moved/file.txt\nD ${prefix}delete.txt\n');
      expect(await File('${root.path}/add.txt').readAsString(), 'created\n');
      expect(await File('${root.path}/moved/file.txt').readAsString(), 'new\n');
      expect(await File('${root.path}/update.txt').exists(), isFalse);
      expect(await File('${root.path}/delete.txt').exists(), isFalse);
    });
  }

  for (final opener in ['<<EOF', "<<'EOF'", '<<"EOF"']) {
    test('Codex lenient heredoc $opener', () async {
      await applyPatch(root.path, '$opener\n*** Begin Patch\n*** Add File: file.txt\n+hello\n*** End Patch\nEOF\n', cancellation: cancellation);
      expect(await File('${root.path}/file.txt').readAsString(), 'hello\n');
    });
  }

  for (final (name, patch, diagnostic) in <(String, String, String)>[
    ('bad first line', 'bad', "The first line of the patch must be '*** Begin Patch'"),
    ('bad last line', '*** Begin Patch\nbad', "The last line of the patch must be '*** End Patch'"),
    ('empty patch', '*** Begin Patch\n*** End Patch', 'No files were modified.'),
    ('empty update', '*** Begin Patch\n*** Update File: file.txt\n*** End Patch', "Update file hunk for path 'file.txt' is empty"),
    ('empty chunk', '*** Begin Patch\n*** Update File: file.txt\n@@\n*** End Patch', 'Update hunk does not contain any lines'),
    ('consecutive empty chunks', '*** Begin Patch\n*** Update File: file.txt\n@@\n@@\n-old\n+new\n*** End Patch', 'Unexpected line found in update hunk'),
    ('invalid header', '*** Begin Patch\n*** Frobnicate File: foo\n*** End Patch', 'not a valid hunk header'),
    ('invalid update line', '*** Begin Patch\n*** Update File: file.txt\n@@\n-old\n+new\nbad\n*** End Patch', 'Expected update hunk to start with a @@ context marker'),
    ('lines after EOF', '*** Begin Patch\n*** Update File: file.txt\n@@\n-old\n+new\n*** End of File\n+invalid\n*** End Patch', 'Expected update hunk to start with a @@ context marker'),
    ('mismatched heredoc quotes', '<<"EOF\'\n*** Begin Patch\n*** End Patch\nEOF', "The first line of the patch must be '*** Begin Patch'"),
    ('unterminated heredoc patch', '<<EOF\n*** Begin Patch\n*** Update File: file.txt\nEOF', "The last line of the patch must be '*** End Patch'"),
    ('content after patch', '*** Begin Patch\n*** Add File: file.txt\n+hello\n*** End Patch\nextra', "The last line of the patch must be '*** End Patch'"),
    ('unsupported environment', '*** Begin Patch\n*** Environment ID: remote\n*** Add File: other.txt\n+hello\n*** End Patch', 'apply_patch environment selection is unavailable for this turn'),
    ('empty environment', '*** Begin Patch\n*** Environment ID:   \n*** Add File: other.txt\n+hello\n*** End Patch', 'apply_patch environment_id cannot be empty'),
    ('duplicate environment', '*** Begin Patch\n*** Environment ID: first\n*** Environment ID: second\n*** Add File: other.txt\n+hello\n*** End Patch', 'apply_patch environment_id cannot be specified more than once'),
  ]) {
    test('Codex rejects $name before touching files', () async {
      await File('${root.path}/file.txt').writeAsString('old\n');
      await expectLater(applyPatch(root.path, patch, cancellation: cancellation), throwsA(predicate<Object>((error) => error.toString().contains(diagnostic))));
      expect(await File('${root.path}/file.txt').readAsString(), 'old\n');
    });
  }

  for (final (name, original, body, diagnostic) in <(String, String, String, String)>[
    ('missing context', 'line1\nline2\n', '@@\n-missing\n+changed', 'Failed to find expected lines in'),
    ('overlapping EOF chunks', 'one\n', '@@\n-one\n+first\n@@\n-one\n+second\n*** End of File', 'Failed to find expected lines in'),
    ('pattern longer than file', 'one\n', '@@\n-one\n-two\n+new', 'Failed to find expected lines in'),
    ('missing skip-ahead context', 'one\n', '@@ missing\n-one\n+new', "Failed to find context 'missing' in"),
  ]) {
    test('Codex rejects $name with the missing text', () async {
      await File('${root.path}/file.txt').writeAsString(original);
      final expectedLine = name.startsWith('missing') ? 'missing' : name == 'pattern longer than file' ? 'one\ntwo' : 'one';
      await expectLater(apply('*** Update File: file.txt\n$body'), throwsA(predicate<Object>((error) =>
        error.toString().contains(diagnostic) && error.toString().contains('${root.path}/file.txt') && error.toString().contains(expectedLine))));
      expect(await File('${root.path}/file.txt').readAsString(), original);
    });
  }

  test('Codex partial success reports committed changes before a later failure', () async {
    Json? delta;
    await expectLater(apply('*** Add File: created.txt\n+hello\n*** Update File: missing.txt\n@@\n-old\n+new', onPatch: (value) async { delta = value; }), throwsA(anything));
    expect(await File('${root.path}/created.txt').readAsString(), 'hello\n');
    expect(delta, {'exact': true, 'changes': [
      {'path': '${root.path}/created.txt', 'type': 'A', 'oldContent': null, 'newContent': 'hello\n', 'movePath': null, 'overwrittenMoveContent': null},
    ]});
  });

  for (final (name, original, body, expected, diff) in <(String, String, String, String, String)>[
    ('multiple chunks', 'foo\nbar\nbaz\nqux\n', '@@\n foo\n-bar\n+BAR\n@@\n baz\n-qux\n+QUX',
      'foo\nBAR\nbaz\nQUX\n', '@@ -1,4 +1,4 @@\n foo\n-bar\n+BAR\n baz\n-qux\n+QUX\n'),
    ('first line', 'foo\nbar\nbaz\n', '@@\n-foo\n+FOO\n bar\n',
      'FOO\nbar\nbaz\n', '@@ -1,2 +1,2 @@\n-foo\n+FOO\n bar\n'),
    ('last line', 'foo\nbar\nbaz\n', '@@\n foo\n bar\n-baz\n+BAZ\n',
      'foo\nbar\nBAZ\n', '@@ -2,2 +2,2 @@\n bar\n-baz\n+BAZ\n'),
    ('append at EOF', 'foo\nbar\nbaz\n', '@@\n+quux\n*** End of File\n',
      'foo\nbar\nbaz\nquux\n', '@@ -3 +3,2 @@\n baz\n+quux\n'),
    ('interleaved', 'a\nb\nc\nd\ne\nf\n', '@@\n a\n-b\n+B\n@@\n d\n-e\n+E\n@@\n f\n+g\n*** End of File',
      'a\nB\nc\nd\nE\nf\ng\n', '@@ -1,6 +1,7 @@\n a\n-b\n+B\n c\n d\n-e\n+E\n f\n+g\n'),
  ]) {
    test('Codex native patch diff: $name', () async {
      final target = File('${root.path}/file.txt');
      await target.writeAsString(original);
      final items = <Json>[];
      await applyPatch(root.path, '*** Begin Patch\n*** Update File: file.txt\n$body\n*** End Patch',
        cancellation: cancellation, onItem: (phase, item) async {
          if (phase == 'completed') items.add(jsonObject(jsonDecode(jsonEncode(item))));
        }, onPatch: (delta) async {
          expect(await target.readAsString(), expected, reason: 'Only committed contents may be acknowledged');
          expect(delta['changes'], [
            {'path': target.path, 'type': 'M', 'oldContent': original, 'newContent': expected, 'movePath': null, 'overwrittenMoveContent': null},
          ]);
        });
      expect(items.single['changes'], {target.path: {'type': 'update', 'move_path': null, 'unified_diff': diff}});
    });
  }

  test('Codex unreadable overwritten files produce inexact deltas', () async {
    for (final move in [false, true]) {
      final binary = File('${root.path}/binary.dat');
      await binary.writeAsBytes([0xff, 0xfe, 0xfd]);
      await File('${root.path}/source.txt').writeAsString('before\n');
      Json? delta;
      await apply(move ? '*** Update File: source.txt\n*** Move to: binary.dat\n@@\n-before\n+after' : '*** Add File: binary.dat\n+text',
        onPatch: (value) async { delta = value; });
      expect(delta!['exact'], isFalse);
      expect(await binary.readAsString(), move ? 'after\n' : 'text\n');
    }
  });

  test('Codex deleting a symlink leaves its target and records an inexact delta', () async {
    final target = File('${root.path}/target.txt');
    await target.writeAsString('target\n');
    final link = Link('${root.path}/link.txt');
    await link.create(target.path);
    Json? delta;
    await apply('*** Delete File: link.txt', onPatch: (value) async { delta = value; });
    expect(await link.exists(), isFalse);
    expect(await target.readAsString(), 'target\n');
    expect(delta!['exact'], isFalse);
  }, skip: Platform.isWindows ? 'Unix symlink semantics' : false);

  test('Codex default follows leaf and ancestor symlinks when updating files', () async {
    final directory = await Directory('${root.path}/target').create();
    final target = File('${directory.path}/file.txt');
    await target.writeAsString('before\n');
    final leaf = Link('${root.path}/leaf.txt'), ancestor = Link('${root.path}/linked');
    await leaf.create(target.path);
    await ancestor.create(directory.path);
    await apply('*** Update File: leaf.txt\n@@\n-before\n+after leaf');
    await apply('*** Update File: linked/file.txt\n@@\n-after leaf\n+after ancestor');
    expect(await target.readAsString(), 'after ancestor\n');
    expect(await leaf.exists(), isTrue);
    expect(await ancestor.exists(), isTrue);
  }, skip: Platform.isWindows ? 'Unix symlink semantics' : false);

  test('cancelling after verification closes the patch lifecycle without committing', () async {
    final phases = <String>[];
    final target = File('${root.path}/file.txt');
    await target.writeAsString('before\n');
    await expectLater(applyPatch(root.path, '*** Begin Patch\n*** Update File: file.txt\n@@\n-before\n+after\n*** End Patch',
      cancellation: cancellation, verifyBeforeApply: true, onItem: (phase, item) async {
        phases.add(phase);
        if (phase == 'started') { cancellation.cancel(); }
        else { expect(item['status'], 'failed'); }
      }, onPatch: (_) async { fail('A cancelled proposal has no committed delta'); }), throwsA(isA<CancelledException>()));
    expect(phases, ['started', 'completed']);
    expect(await target.readAsString(), 'before\n');
  });

  for (final move in [false, true]) {
    test('Codex failed ${move ? 'move removal' : 'write'} reports the committed prefix', () async {
      final locked = await Directory('${root.path}/locked').create();
      final source = File('${locked.path}/source.txt');
      await source.writeAsString('before\n');
      final chmod = await Process.run('chmod', ['555', locked.path]);
      expect(chmod.exitCode, 0);
      Json? delta;
      try {
        await expectLater(apply(move ? '*** Update File: locked/source.txt\n*** Move to: out/dest.txt\n@@\n-before\n+after' : '*** Add File: locked/new.txt\n+after',
          onPatch: (value) async { delta = value; }), throwsA(anything));
        expect(delta!['exact'], move);
        if (move) {
          expect(await source.readAsString(), 'before\n');
          expect(await File('${root.path}/out/dest.txt').readAsString(), 'after\n');
          expect(delta!['changes'], [
            {'path': '${root.path}/out/dest.txt', 'type': 'A', 'oldContent': null, 'newContent': 'after\n', 'movePath': null, 'overwrittenMoveContent': null},
          ]);
        }
      } finally { await Process.run('chmod', ['755', locked.path]); }
    }, skip: Platform.isWindows ? 'Unix permissions' : false);
  }
}

Future<void> _copy(Directory source, Directory destination) async {
  if (!await source.exists()) return;
  await for (final entry in source.list(recursive: true)) {
    final path = '${destination.path}/${entry.path.substring(source.path.length + 1)}';
    if (entry is Directory) { await Directory(path).create(recursive: true); }
    else if (entry is File) {
      await File(path).parent.create(recursive: true);
      await entry.copy(path);
    }
  }
}

Future<Map<String, Object?>> _snapshot(Directory root) async {
  final result = <String, Object?>{};
  if (!await root.exists()) return result;
  await for (final entry in root.list(recursive: true)) {
    final name = entry.path.substring(root.path.length + 1);
    result[name] = entry is File ? await entry.readAsBytes() : null;
  }
  return result;
}
