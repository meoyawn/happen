import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'release_credentials.dart';
import 'release_signature.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isMacOS) throw UnsupportedError('This target builds the macOS release');
  final root = File.fromUri(Platform.script).absolute.parent.parent.parent.parent;
  final cache = Directory('${root.path}/.local/release-macos')..createSync(recursive: true);
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  final lock = await File('${cache.path}/build.lock').open(mode: FileMode.append);
  final cancelLock = CancellationHook(cancellation, () => unawaited(lock.close().catchError((Object _) {})));
  var locked = false;
  Directory? work;
  try {
    await lock.lock(FileLock.blockingExclusive);
    locked = true;
    cancelLock.dispose();
    cancellation.throwIfCancelled();
    final sdk = await _releaseFlutter(root, cancellation);
    final flutter = '${sdk.path}/bin/flutter';
    final credentials = releaseCredentials();
    final identity = await _signingIdentity(root, cancellation, credentials.identity);
    final environment = {
      'FLUTTER_ROOT': sdk.path,
      'PATH': '${sdk.path}/bin:${Platform.environment['PATH'] ?? ''}',
      'FLUTTER_XCODE_CODE_SIGN_IDENTITY': identity.$1,
      'FLUTTER_XCODE_CODE_SIGN_STYLE': 'Manual',
      'FLUTTER_XCODE_ENABLE_HARDENED_RUNTIME': 'YES',
      // Xcode's direct build defaults are unsuitable for notarization.
      'FLUTTER_XCODE_CODE_SIGN_INJECT_BASE_ENTITLEMENTS': 'NO',
      if (identity.$2 == 'Developer ID Application')
        'FLUTTER_XCODE_OTHER_CODE_SIGN_FLAGS': '--timestamp',
      if (credentials.teamId case final team? when team.isNotEmpty)
        'FLUTTER_XCODE_DEVELOPMENT_TEAM': team,
    };
    final version = jsonObject(jsonDecode(await _run(flutter, ['--version', '--machine'], sdk.path,
      cancellation, capture: true, environment: environment)));
    final revision = (await _run('git', ['rev-parse', 'HEAD'], sdk.path, cancellation, capture: true)).trim();
    if (version['channel'] != 'stable' || version['frameworkRevision'] != revision) {
      throw StateError('Release Flutter does not match its stable checkout: $version');
    }
    stdout.writeln('Release toolchain: Flutter ${version['frameworkVersion']}, '
      'bundled Dart ${version['dartSdkVersion']}, revision $revision, SDK ${sdk.path}.');
    stdout.writeln('Release signing: ${identity.$2}.');

    // Flutter rewrites package_config.json and Xcode's generated SDK paths.
    // Build a working-source snapshot so release cannot redirect a live reload
    // to the unpatched SDK (or share its native asset build products).
    work = await cache.createTemp('source-');
    await _copySources(root, work, cancellation);
    final desktop = '${work.path}/packages/desktop';
    await _run(flutter, ['pub', 'get'], work.path, cancellation, environment: environment);
    final configFile = File('${work.path}/.dart_tool/package_config.json');
    final config = jsonObject(jsonDecode(await configFile.readAsString()));
    final framework = (config['packages'] as List).map(jsonObject).singleWhere((package) => package['name'] == 'flutter');
    final resolvedFramework = Directory.fromUri(configFile.uri.resolve(framework['rootUri'] as String));
    if (await resolvedFramework.resolveSymbolicLinks() != await Directory('${sdk.path}/packages/flutter').resolveSymbolicLinks()) {
      throw StateError('Release dependencies resolved Flutter outside the Homebrew SDK');
    }
    await _run(flutter, ['build', 'macos', '--release', '--no-pub', ...arguments], desktop,
      cancellation, environment: environment);
    await _requireClean(sdk, cancellation);
    final bundle = '$desktop/build/macos/Build/Products/Release/Happen.app';
    verifyReleaseSignature(Directory(bundle), requireDeveloperId: _requireDeveloperId,
      expectedTeamId: credentials.teamId);
    final output = Directory('${root.path}/packages/desktop/build/macos/Build/Products/Release');
    await output.create(recursive: true);
    final staged = await output.createTemp('.release-');
    try {
      await _run('/usr/bin/ditto', [bundle, '${staged.path}/Happen.app'], root.path, cancellation);
      cancellation.throwIfCancelled();
      final destination = Directory('${output.path}/Happen.app');
      if (await destination.exists()) await destination.delete(recursive: true);
      await Directory('${staged.path}/Happen.app').rename(destination.path);
      await File('${output.path}/toolchain.json').writeAsString('${const JsonEncoder.withIndent('  ').convert({
        'upstream': version['repositoryUrl'], 'channel': 'stable', 'framework_revision': revision,
        'distribution': Platform.environment['GITHUB_ACTIONS'] == 'true' ? 'mise' :
          Platform.environment.containsKey('HAPPEN_RELEASE_FLUTTER_EXECUTABLE') ? 'provided' : 'homebrew',
        'flutter': version['frameworkVersion'], 'dart': version['dartSdkVersion'],
        'engine_revision': version['engineRevision'], 'sdk': sdk.path,
      })}\n');
      stdout.writeln('Built ${destination.path} with Flutter and Dart.');
    } finally { await staged.delete(recursive: true); }
  } finally {
    if (work != null) await work.delete(recursive: true);
    cancelLock.dispose();
    if (locked) await lock.unlock();
    try { await lock.close(); } catch (_) { /* Cancellation can close a waiting lock. */ }
    for (final signal in signals) { await signal.cancel(); }
  }
}

bool get _requireDeveloperId => Platform.environment['HAPPEN_REQUIRE_DEVELOPER_ID'] == '1';

Future<Directory> _releaseFlutter(Directory root, CancellationToken cancellation) async {
  final configured = Platform.environment['HAPPEN_RELEASE_FLUTTER_EXECUTABLE'] ??
    (Platform.environment['GITHUB_ACTIONS'] == 'true'
      ? (await _run('mise', ['which', 'flutter'], root.path, cancellation, capture: true)).trim()
      : null);
  final executable = configured == null
    ? File('${(await _run('brew', ['--prefix'], root.path, cancellation, capture: true)).trim()}/bin/flutter')
    : File(configured);
  if (!await executable.exists()) throw StateError('Release Flutter SDK not found: ${executable.path}');
  final sdk = File(await executable.resolveSymbolicLinks()).parent.parent;
  await _requireClean(sdk, cancellation);
  return sdk;
}

Future<(String, String)> _signingIdentity(Directory root, CancellationToken cancellation, String? requested) async {
  final available = await _run('/usr/bin/security', ['find-identity', '-v', '-p', 'codesigning'],
    root.path, cancellation, capture: true);
  final identities = [
    for (final match in RegExp(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"]+)"', multiLine: true).allMatches(available))
      (match.group(1)!, match.group(2)!),
  ];
  final eligible = identities.where((identity) =>
    identity.$2.startsWith('Developer ID Application: ') ||
    !_requireDeveloperId && identity.$2.startsWith('Apple Development: ')).toList();
  if (requested != null && requested.isNotEmpty) {
    final matches = eligible.where((identity) => identity.$1 == requested || identity.$2 == requested).toSet();
    if (matches.length != 1) throw StateError('HAPPEN_CODESIGN_IDENTITY must select one valid release signing identity');
    final selected = matches.single;
    return (selected.$1, selected.$2.startsWith('Developer ID Application: ') ? 'Developer ID Application' : 'Apple Development');
  }
  for (final kind in ['Developer ID Application: ', if (!_requireDeveloperId) 'Apple Development: ']) {
    final matches = eligible.where((identity) => identity.$2.startsWith(kind)).map((identity) => identity.$1).toSet();
    if (matches.length > 1) throw StateError('Multiple ${kind.trim()} identities; set HAPPEN_CODESIGN_IDENTITY');
    if (matches.length == 1) return (matches.single, kind.trim().replaceFirst(':', ''));
  }
  throw StateError('No release signing identity found. Install a Developer ID Application certificate or Apple Development certificate.');
}

Future<void> _requireClean(Directory sdk, CancellationToken cancellation) async {
  final status = await _run('git', ['status', '--porcelain=v1', '--untracked-files=normal'], sdk.path, cancellation, capture: true);
  if (status.isNotEmpty) throw StateError('Release SDK has local changes: ${sdk.path}\n$status');
}

Future<void> _copySources(Directory source, Directory destination, CancellationToken cancellation) async {
  final paths = await _run('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    source.path, cancellation, capture: true);
  for (final path in paths.split('\u0000').where((path) => path.isNotEmpty).toSet()) {
    cancellation.throwIfCancelled();
    if (path == 'third_party/flutter') continue; // Development SDK, never a release input.
    final from = '${source.path}/$path', to = '${destination.path}/$path';
    switch (await FileSystemEntity.type(from, followLinks: false)) {
      case FileSystemEntityType.file:
        await File(to).parent.create(recursive: true);
        await File(from).copy(to);
      case FileSystemEntityType.link:
        await Link(to).parent.create(recursive: true);
        await Link(to).create(await Link(from).target());
      case FileSystemEntityType.directory:
        // Git lists initialized submodules as directories, not their files.
        await _copySources(Directory(from), Directory(to), cancellation);
      case FileSystemEntityType.notFound:
        break; // Respect working-tree deletions.
      default:
        throw StateError('Unsupported source entry: $from');
    }
  }
}

Future<String> _run(String command, List<String> arguments, String cwd, CancellationToken cancellation,
    {bool capture = false, Map<String, String>? environment}) async {
  cancellation.throwIfCancelled();
  final process = await Process.start(command, arguments, workingDirectory: cwd, environment: environment);
  final hook = CancellationHook(cancellation, () => process.kill());
  try {
    final output = StringBuffer();
    await Future.wait([
      process.stdout.transform(utf8.decoder).forEach((text) { if (capture) { output.write(text); } else { stdout.write(text); } }),
      process.stderr.forEach(stderr.add),
    ]).asCancellable(cancellation);
    final code = await process.exitCode.asCancellable(cancellation);
    if (code != 0) throw ProcessException(command, arguments, 'Release build step failed', code);
    return output.toString();
  } finally { hook.dispose(); }
}
