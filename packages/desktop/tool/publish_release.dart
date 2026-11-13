import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

Future<void> main() async {
  final commit = Platform.environment['GITHUB_SHA'];
  if (Platform.environment['GITHUB_REF'] != 'refs/heads/master' ||
      commit == null || !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit) ||
      Platform.environment['GH_REPO'] == null || Platform.environment['GH_TOKEN'] == null) {
    throw StateError('Publishing requires a master push with GitHub release permissions');
  }
  final desktop = File.fromUri(Platform.script).absolute.parent.parent;
  final dmg = File('${desktop.path}/build/macos/Build/Products/Release/Happen-macos.dmg');
  if (!dmg.existsSync()) throw StateError('Notarized macOS DMG is missing');
  final tag = 'master-$commit';
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  try {
    final existing = await _run(['release', 'view', tag], cancellation);
    if (existing.$1 == 0) {
      stdout.writeln('Release $tag already exists.');
      return;
    }
    final published = await _run(['release', 'create', tag, dmg.path,
      '--target', commit, '--title', 'Happen ${commit.substring(0, 12)}',
      '--notes', 'Automated macOS release for commit $commit.',
      '--prerelease', '--latest=false'], cancellation);
    if (published.$1 != 0) throw StateError('GitHub release publication failed: ${published.$3}');
    stdout.write(published.$2);
  } finally {
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<(int, String, String)> _run(List<String> arguments, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final process = await Process.start('gh', arguments);
  final hook = CancellationHook(cancellation, () => process.kill());
  try {
    final output = StringBuffer(), errors = StringBuffer();
    await Future.wait([
      process.stdout.transform(utf8.decoder).forEach(output.write),
      process.stderr.transform(utf8.decoder).forEach(errors.write),
    ]).asCancellable(cancellation);
    return (await process.exitCode.asCancellable(cancellation), output.toString(), errors.toString());
  } finally { hook.dispose(); }
}
