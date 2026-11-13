import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('desktop releases reserve, reuse, and advance patch versions for master sources', () async {
    final fixture = await Directory.systemTemp.createTemp('happen-release-test-');
    addTearDown(() => fixture.delete(recursive: true));
    final origin = Directory('${fixture.path}/origin.git');
    final checkout = Directory('${fixture.path}/checkout');
    await _run('git', ['init', '--bare', origin.path], fixture.path);
    await _run('git', ['init', '--initial-branch=master', checkout.path], fixture.path);
    await _run('git', ['remote', 'add', 'origin', origin.path], checkout.path);
    await _run('git', ['config', 'user.name', 'Release Test'], checkout.path);
    await _run('git', ['config', 'user.email', 'release@example.test'], checkout.path);
    final manifest = File('${checkout.path}/packages/desktop/pubspec.yaml');
    await manifest.parent.create(recursive: true);
    await manifest.writeAsString('name: desktop\nversion: 0.1.0+1\nresolution: workspace\n');
    final readme = File('${checkout.path}/README.md');
    await readme.writeAsString('first source\n');
    await _run('git', ['add', '.'], checkout.path);
    await _run('git', ['commit', '-m', 'First source'], checkout.path);
    await _run('git', ['push', '-u', 'origin', 'master'], checkout.path);
    final first = (await _run('git', ['rev-parse', 'HEAD'], checkout.path)).trim();

    Future<String> prepare(String source) async {
      final output = File('${fixture.path}/output')..writeAsStringSync('');
      await _run(Platform.resolvedExecutable,
        ['--disable-dart-dev', '${Directory.current.path}/packages/desktop/tool/prepare_release.dart'],
        checkout.path, environment: {
          ...Platform.environment,
          'GITHUB_ACTIONS': 'true',
          'GITHUB_REPOSITORY': 'meoyawn/happen',
          'GITHUB_REF': 'refs/heads/master',
          'GITHUB_SHA': source,
          'GITHUB_OUTPUT': output.path,
        });
      return output.readAsString();
    }

    expect(await prepare(first), 'tag=v0.1.0\nsource=$first\n');
    final firstTagCommit = (await _run('git', ['rev-parse', 'v0.1.0^{commit}'], checkout.path)).trim();
    expect((await _run('git', ['rev-parse', '$firstTagCommit^'], checkout.path)).trim(), first);
    expect(await _run('git', ['show', 'v0.1.0:packages/desktop/pubspec.yaml'], checkout.path),
      'name: desktop\nversion: 0.1.0+1\nresolution: workspace\n');
    expect((await _run('git', ['ls-remote', '--tags', 'origin', 'v0.1.0'], checkout.path)).trim(),
      contains(firstTagCommit));

    await _run('git', ['checkout', '--detach', first], checkout.path);
    expect(await prepare(first), 'tag=v0.1.0\nsource=$first\n');
    expect((await _run('git', ['tag', '--list', 'v*'], checkout.path)).trim(), 'v0.1.0');

    await _run('git', ['checkout', 'master'], checkout.path);
    await readme.writeAsString('second source\n');
    await _run('git', ['add', 'README.md'], checkout.path);
    await _run('git', ['commit', '-m', 'Second source'], checkout.path);
    await _run('git', ['push', 'origin', 'master'], checkout.path);
    final second = (await _run('git', ['rev-parse', 'HEAD'], checkout.path)).trim();
    await _run('git', ['checkout', '--detach', first], checkout.path);
    expect(await prepare(first), isEmpty);
    await _run('git', ['checkout', '--detach', second], checkout.path);
    expect(await prepare(second), 'tag=v0.1.1\nsource=$second\n');
    expect(await _run('git', ['show', 'v0.1.1:packages/desktop/pubspec.yaml'], checkout.path),
      'name: desktop\nversion: 0.1.1+2\nresolution: workspace\n');
    expect((await _run('git', ['rev-parse', 'v0.1.1^'], checkout.path)).trim(), second);
  });
}

Future<String> _run(String command, List<String> arguments, String directory,
    {Map<String, String>? environment}) async {
  final result = await Process.run(command, arguments, workingDirectory: directory, environment: environment);
  expect(result.exitCode, 0, reason: '$command ${arguments.join(' ')}: ${result.stderr}');
  return result.stdout as String;
}
