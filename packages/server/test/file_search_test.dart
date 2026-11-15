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

    expect(await paths('apps/client/crates/des'), contains('apps/client/crates/des/src/lib.rs'));
    final children = await paths('apps/client/');
    expect(children, isNotEmpty);
    expect(children.first, 'apps/client/crates/');
    expect(children, isNot(contains('apps/client/')));
    expect(children.where((path) => path.startsWith('apps/client-signing/')), isEmpty);
  });
}
