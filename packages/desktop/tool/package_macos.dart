import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'release_credentials.dart';
import 'release_signature.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isMacOS) throw UnsupportedError('macOS packaging requires macOS');
  if (arguments.isNotEmpty && !(arguments.length == 1 && arguments.single == '--notary-log')) {
    throw StateError('Usage: package_macos.dart [--notary-log]');
  }
  final desktop = File.fromUri(Platform.script).absolute.parent.parent;
  final output = Directory('${desktop.path}/build/macos/Build/Products/Release');
  final app = Directory('${output.path}/Happen.app');
  final credentials = releaseCredentials();
  final identity = credentials.identity;
  final key = credentials.notaryKeyPath;
  final keyId = credentials.notaryKeyId;
  final issuer = credentials.notaryIssuerId;
  if (identity == null || key == null || keyId == null || issuer == null ||
      !identity.startsWith('Developer ID Application: ')) {
    throw StateError('Developer ID signing and notary credentials are required to package a public release');
  }
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  Directory? temporary;
  try {
    if (arguments.isNotEmpty) {
      final submissionId = Platform.environment['HAPPEN_NOTARY_SUBMISSION_ID'];
      if (submissionId == null) throw StateError('Set HAPPEN_NOTARY_SUBMISSION_ID to inspect Apple notarization');
      stdout.writeln(await _notaryIssues(submissionId, key, keyId, issuer, cancellation));
      return;
    }
    verifyReleaseSignature(app, requireDeveloperId: true, expectedTeamId: credentials.teamId);
    temporary = await output.createTemp('.package-');
    final zip = '${temporary.path}/Happen.zip';
    await _run('/usr/bin/ditto', ['-c', '-k', '--keepParent', app.path, zip], cancellation);
    await _notarize(zip, key, keyId, issuer, cancellation);
    await _run('/usr/bin/xcrun', ['stapler', 'staple', app.path], cancellation);
    await _run('/usr/bin/xcrun', ['stapler', 'validate', app.path], cancellation);
    verifyReleaseSignature(app, requireDeveloperId: true, expectedTeamId: credentials.teamId);
    await _run('/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=2', app.path], cancellation);

    final image = Directory('${temporary.path}/image')..createSync();
    await _run('/usr/bin/ditto', [app.path, '${image.path}/Happen.app'], cancellation);
    await Link('${image.path}/Applications').create('/Applications');
    final dmg = '${temporary.path}/Happen-macos.dmg';
    await _run('/usr/bin/hdiutil', ['create', '-volname', 'Happen', '-srcfolder', image.path,
      '-ov', '-format', 'UDZO', dmg], cancellation);
    await _run('/usr/bin/hdiutil', ['verify', dmg], cancellation);
    await _run('/usr/bin/codesign', ['--force', '--sign', identity, '--timestamp', dmg], cancellation);
    await _notarize(dmg, key, keyId, issuer, cancellation);
    await _run('/usr/bin/xcrun', ['stapler', 'staple', dmg], cancellation);
    await _run('/usr/bin/xcrun', ['stapler', 'validate', dmg], cancellation);
    await _run('/usr/bin/codesign', ['--verify', '--strict', dmg], cancellation);
    cancellation.throwIfCancelled();
    final destination = File('${output.path}/Happen-macos.dmg');
    await File(dmg).rename(destination.path);
    stdout.writeln('Packaged ${destination.path}');
  } finally {
    if (temporary != null) await temporary.delete(recursive: true);
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<void> _notarize(String path, String key, String keyId, String issuer, CancellationToken cancellation) async {
  final result = await _run('/usr/bin/xcrun', ['notarytool', 'submit', path, '--key', key,
    '--key-id', keyId, '--issuer', issuer, '--wait', '--output-format', 'json'], cancellation, capture: true);
  final submission = jsonDecode(result);
  if (submission is! Map<String, dynamic> || submission['status'] != 'Accepted') {
    if (submission is Map<String, dynamic>) {
      final id = submission['id'];
      if (id is String) {
        try { stderr.writeln(await _notaryIssues(id, key, keyId, issuer, cancellation)); }
        catch (error) { stderr.writeln('Could not retrieve Apple notarization log: $error'); }
      }
    }
    throw StateError('Apple notarization did not accept $path: $result');
  }
  stdout.writeln('Apple notarization accepted ${File(path).uri.pathSegments.last}.');
}

Future<String> _notaryIssues(String id, String key, String keyId, String issuer, CancellationToken cancellation) async {
  final report = await _run('/usr/bin/xcrun', ['notarytool', 'log', id, '--key', key,
    '--key-id', keyId, '--issuer', issuer, '--output-format', 'json'], cancellation, capture: true);
  final decoded = jsonDecode(report);
  if (decoded is! Map<String, dynamic>) throw StateError('Invalid Apple notarization log');
  return jsonEncode(decoded['issues'] ?? []);
}

Future<String> _run(String command, List<String> arguments, CancellationToken cancellation, {bool capture = false}) async {
  cancellation.throwIfCancelled();
  final process = await Process.start(command, arguments);
  final hook = CancellationHook(cancellation, () => process.kill());
  try {
    final output = StringBuffer();
    await Future.wait([
      process.stdout.transform(utf8.decoder).forEach((text) { if (capture) { output.write(text); } else { stdout.write(text); } }),
      process.stderr.forEach(stderr.add),
    ]).asCancellable(cancellation);
    final code = await process.exitCode.asCancellable(cancellation);
    if (code != 0) throw StateError('macOS packaging step failed: $command (exit $code)');
    return output.toString();
  } finally { hook.dispose(); }
}
