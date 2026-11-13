import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'release_version.dart';

Future<void> main() async {
  final source = Platform.environment['GITHUB_SHA'];
  final tag = Platform.environment['HAPPEN_RELEASE_TAG'];
  final expected = tag == null ? null : desktopTagVersion(tag);
  if (Platform.environment['GITHUB_REF'] != 'refs/heads/master' ||
      Platform.environment['GITHUB_REPOSITORY'] != 'meoyawn/happen' ||
      source == null || !RegExp(r'^[0-9a-f]{40}$').hasMatch(source) ||
      tag == null || expected == null || Platform.environment['GH_REPO'] == null ||
      Platform.environment['GH_TOKEN'] == null) {
    throw StateError('Publishing requires a versioned desktop release from a master push');
  }
  final desktop = File.fromUri(Platform.script).absolute.parent.parent;
  final dmg = File('${desktop.path}/build/macos/Build/Products/Release/Happen-macos.dmg');
  if (!dmg.existsSync()) throw StateError('Notarized macOS DMG is missing');
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  try {
    final head = (await _checked('git', ['rev-parse', 'HEAD'], cancellation)).trim();
    final tagged = (await _checked('git', ['rev-parse', '$tag^{commit}'], cancellation)).trim();
    final parent = (await _checked('git', ['rev-parse', 'HEAD^'], cancellation)).trim();
    final message = await _checked('git', ['show', '-s', '--format=%B', 'HEAD'], cancellation);
    final trailer = RegExp(r'^Source-commit: ([0-9a-f]{40})$', multiLine: true).firstMatch(message)?.group(1);
    final manifest = await File('${desktop.path}/pubspec.yaml').readAsString();
    final version = desktopVersion(manifest);
    if (head != tagged || parent != source || trailer != source ||
        compareDesktopVersions(expected, version) != 0) {
      throw StateError('Release tag, source commit, and desktop version do not match');
    }

    final existing = await _run('gh', ['release', 'view', tag, '--json', 'assets,isDraft,isPrerelease'], cancellation);
    if (existing.$1 == 0) {
      final release = jsonDecode(existing.$2) as Map<String, dynamic>;
      if (release['isDraft'] != false || release['isPrerelease'] != false) {
        throw StateError('Existing $tag is not a published stable release');
      }
      final assets = release['assets'] as List<dynamic>;
      if (assets.any((asset) => asset is Map && asset['name'] == dmg.uri.pathSegments.last)) {
        stdout.writeln('Release $tag already contains ${dmg.uri.pathSegments.last}.');
        return;
      }
      await _checked('gh', ['release', 'upload', tag, dmg.path], cancellation);
      stdout.writeln('Uploaded ${dmg.uri.pathSegments.last} to $tag.');
      return;
    }

    final published = await _checked('gh', ['release', 'create', tag, dmg.path,
      '--verify-tag', '--target', head, '--title', 'Happen ${tag.substring(1)}',
      '--notes', 'Developer ID signed and notarized macOS DMG.\n\nSource commit: $source.',
      '--latest'], cancellation);
    stdout.write(published);
  } finally {
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<String> _checked(String command, List<String> arguments, CancellationToken cancellation) async {
  final result = await _run(command, arguments, cancellation);
  if (result.$1 != 0) throw StateError('$command ${arguments.first} failed: ${result.$3}');
  return result.$2;
}

Future<(int, String, String)> _run(String command, List<String> arguments, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final process = await Process.start(command, arguments);
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
