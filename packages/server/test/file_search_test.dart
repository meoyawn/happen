import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/src/file_search.dart';
import 'package:test/test.dart';

void main() {
  test('search enters an initialized Git submodule and stays in the selected folder', () async {
    final root = await Directory.systemTemp.createTemp('happen-file-search-');
    addTearDown(() => root.delete(recursive: true));

    Future<void> git(String cwd, List<String> arguments) async {
      final result = await Process.run('git', arguments, workingDirectory: cwd);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    final source = await Directory('${root.path}/source').create();
    await git(source.path, ['init']);
    await Directory('${source.path}/crates/des/src').create(recursive: true);
    await File('${source.path}/crates/des/src/lib.rs').writeAsString('pub fn run() {}\n');
    await git(source.path, ['add', '.']);
    await git(source.path, ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
      'commit', '-m', 'Source']);

    final checkout = await Directory('${root.path}/checkout').create();
    await git(checkout.path, ['init']);
    await Directory('${checkout.path}/apps/client-signing').create(recursive: true);
    await File('${checkout.path}/apps/client-signing/restore.mjs').writeAsString('');
    await git(checkout.path, ['add', '.']);
    await git(checkout.path, ['-c', 'protocol.file.allow=always', 'submodule', 'add', source.path, 'apps/client']);

    final search = FileSearch();
    final cancellation = CancellationToken();
    addTearDown(cancellation.cancel);
    Future<List<String>> paths(String query) async =>
      (await search.search({'cwd': checkout.path, 'query': query}, cancellation))['paths'] as List<String>;

    expect((await search.search({'cwd': checkout.path, 'query': 'apps/client', 'limit': 2}, cancellation))['paths'],
      ['apps/client/', 'apps/client/crates/']);
    expect(await paths('apps/client/crates/des'), contains('apps/client/crates/des/src/lib.rs'));
    final children = await paths('apps/client/');
    expect(children, isNotEmpty);
    expect(children.first, 'apps/client/crates/');
    expect(children, isNot(contains('apps/client/')));
    expect(children.where((path) => path.startsWith('apps/client-signing/')), isEmpty);
  });

  test('files and folders share match ranking within the result limit', () async {
    final root = await Directory.systemTemp.createTemp('happen-file-ranking-');
    addTearDown(() => root.delete(recursive: true));
    Future<void> write(String path) async {
      final file = File('${root.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsString('');
    }

    await write('viewmodel/build.gradle.kts');
    await write('feature/src/ChatViewModel.kt');
    await write('b/target.txt');
    await write('a/target.txt');
    const desktopDart = 'third_party/flutter/packages/flutter_tools/lib/src/build_system/targets/desktop.dart';
    await write(desktopDart);
    await write('desktop_menu.dart');
    await write('packages/desktop/lib/app.dart');
    await Directory('${root.path}/src').create();
    for (var i = 0; i < 80; i++) {
      await Directory('${root.path}/parent-$i/viewmodel').create(recursive: true);
      await write('source-$i.rs');
    }

    final search = FileSearch();
    final cancellation = CancellationToken();
    addTearDown(cancellation.cancel);
    Future<List<String>> paths(String query, int limit) async =>
      (await search.search({'cwd': root.path, 'query': query, 'limit': limit}, cancellation))['paths'] as List<String>;

    for (final (query, limit, expected) in [
      ('', 1, ['a/']),
      ('ViewModel', 2, ['viewmodel/', 'parent-0/viewmodel/']),
      ('VM', 1, ['viewmodel/']),
      ('deskto', 2, ['packages/desktop/', desktopDart]),
      ('deskto', 5, ['packages/desktop/', desktopDart, 'desktop_menu.dart', 'packages/desktop/lib/', 'packages/desktop/lib/app.dart']),
      ('desktop', 2, ['packages/desktop/', desktopDart]),
      ('src', 1, ['src/']),
      ('viewmodel/', 1, ['viewmodel/build.gradle.kts']),
      ('target', 3, ['third_party/flutter/packages/flutter_tools/lib/src/build_system/targets/', 'a/target.txt', 'b/target.txt']),
    ]) {
      expect(await paths(query, limit), expected, reason: query);
    }

    await write('feature/src/src');
    search.clear();
    expect(await paths('src', 1), ['src/']);
  });
}
