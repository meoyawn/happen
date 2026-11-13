import 'dart:async';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'release_version.dart';

Future<void> main() async {
  final source = Platform.environment['GITHUB_SHA'];
  final output = Platform.environment['GITHUB_OUTPUT'];
  if (Platform.environment['GITHUB_ACTIONS'] != 'true' ||
      Platform.environment['GITHUB_REPOSITORY'] != 'meoyawn/happen' ||
      Platform.environment['GITHUB_REF'] != 'refs/heads/master' ||
      source == null || !RegExp(r'^[0-9a-f]{40}$').hasMatch(source) || output == null) {
    throw StateError('Desktop release preparation requires a master push in meoyawn/happen');
  }
  final root = Directory.current.absolute;
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  try {
    if ((await _git(root, ['rev-parse', 'HEAD'], cancellation)).trim() != source) {
      throw StateError('Release preparation requires the checked-out source commit');
    }
    if ((await _git(root, ['status', '--porcelain=v1', '--untracked-files=normal'], cancellation)).isNotEmpty) {
      throw StateError('Release preparation requires a clean checkout');
    }
    await _git(root, ['fetch', '--no-recurse-submodules', 'origin', 'master', '--tags'], cancellation);
    if ((await _git(root, ['rev-parse', 'origin/master'], cancellation)).trim() != source) {
      stdout.writeln('Skipping a superseded master commit.');
      return;
    }

    final manifestPath = 'packages/desktop/pubspec.yaml';
    final manifest = await File('${root.path}/$manifestPath').readAsString();
    final base = desktopVersion(manifest);
    DesktopVersion? latest;
    String? existing;
    final tags = (await _git(root, ['tag', '--list', 'v*'], cancellation)).split('\n');
    for (final tag in tags) {
      final taggedVersion = desktopTagVersion(tag);
      if (taggedVersion == null) continue;
      final commit = (await _git(root, ['rev-parse', '$tag^{commit}'], cancellation)).trim();
      final parents = (await _git(root, ['rev-list', '--parents', '-n', '1', commit], cancellation)).trim().split(' ');
      final message = await _git(root, ['show', '-s', '--format=%B', commit], cancellation);
      final trailer = RegExp(r'^Source-commit: ([0-9a-f]{40})$', multiLine: true).firstMatch(message)?.group(1);
      if (parents.length != 2 || trailer != parents[1]) {
        throw StateError('$tag is not a desktop release commit');
      }
      final taggedManifest = await _git(root, ['show', '$tag:$manifestPath'], cancellation);
      final taggedDesktop = desktopVersion(taggedManifest);
      if (compareDesktopVersions(taggedVersion, taggedDesktop) != 0) {
        throw StateError('$tag does not match its desktop pubspec version');
      }
      if (trailer == source) {
        if (existing != null) throw StateError('Multiple desktop versions tag the same source commit');
        existing = tag;
      }
      if (latest == null || compareDesktopVersions(taggedVersion, latest) > 0) latest = taggedDesktop;
    }
    if (existing != null) {
      await _git(root, ['checkout', '--detach', existing], cancellation);
      await _emit(output, existing, source);
      stdout.writeln('Reusing $existing for source $source.');
      return;
    }

    final next = nextDesktopVersion(base, latest);
    final tag = desktopTag(next);
    await _git(root, ['checkout', '--detach', source], cancellation);
    await File('${root.path}/$manifestPath').writeAsString(withDesktopVersion(manifest, next));
    final date = (await _git(root, ['show', '-s', '--format=%cI', source], cancellation)).trim();
    await _git(root, ['-c', 'user.name=github-actions[bot]',
      '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
      '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--allow-empty', '--only', manifestPath,
      '-m', 'Release $tag', '-m', 'Source-commit: $source'], cancellation,
      environment: {'GIT_AUTHOR_DATE': date, 'GIT_COMMITTER_DATE': date});
    await _git(root, ['tag', tag], cancellation);
    await _git(root, ['push', 'origin', 'refs/tags/$tag'], cancellation);
    await _emit(output, tag, source);
    stdout.writeln('Reserved $tag (${desktopVersionString(next)}) for source $source.');
  } finally {
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<void> _emit(String path, String tag, String source) =>
  File(path).writeAsString('tag=$tag\nsource=$source\n', mode: FileMode.append);

Future<String> _git(Directory root, List<String> arguments, CancellationToken cancellation,
    {Map<String, String>? environment}) async {
  cancellation.throwIfCancelled();
  final process = await Process.start('git', arguments, workingDirectory: root.path, environment: environment);
  final hook = CancellationHook(cancellation, () => process.kill());
  try {
    final output = StringBuffer(), errors = StringBuffer();
    await Future.wait([
      process.stdout.transform(systemEncoding.decoder).forEach(output.write),
      process.stderr.transform(systemEncoding.decoder).forEach(errors.write),
    ]).asCancellable(cancellation);
    final code = await process.exitCode.asCancellable(cancellation);
    if (code != 0) throw ProcessException('git', arguments, errors.toString(), code);
    return output.toString();
  } finally { hook.dispose(); }
}
