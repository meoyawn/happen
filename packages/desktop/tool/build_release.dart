import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

const _upstream = 'https://github.com/flutter/flutter.git';

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
    final sdk = await _stableSdk(cache, cancellation);
    final flutter = '${sdk.path}/bin/flutter';
    final environment = {'FLUTTER_ROOT': sdk.path, 'PATH': '${sdk.path}/bin:${Platform.environment['PATH'] ?? ''}'};
    final version = jsonObject(jsonDecode(await _run(flutter, ['--version', '--machine'], sdk.path,
      cancellation, capture: true, environment: environment)));
    final revision = (await _run('git', ['rev-parse', 'HEAD'], sdk.path, cancellation, capture: true)).trim();
    if (version['channel'] != 'stable' || version['frameworkRevision'] != revision) {
      throw StateError('Release Flutter does not match the verified stable checkout: $version');
    }
    stdout.writeln('Release toolchain: Flutter ${version['frameworkVersion']} stable, '
      'bundled Dart ${version['dartSdkVersion']}, revision $revision.');

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
      throw StateError('Release dependencies resolved Flutter outside the stable SDK');
    }
    await _run(flutter, ['build', 'macos', '--release', '--no-pub', ...arguments], desktop,
      cancellation, environment: environment);
    await _requireClean(sdk, cancellation);
    final bundle = '$desktop/build/macos/Build/Products/Release/Happen.app';
    await _run('/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle], desktop, cancellation);
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
        'upstream': _upstream, 'channel': 'stable', 'framework_revision': revision,
        'flutter': version['frameworkVersion'], 'dart': version['dartSdkVersion'],
        'engine_revision': version['engineRevision'], 'sdk': sdk.path,
      })}\n');
      stdout.writeln('Built ${destination.path} with the unmodified stable SDK.');
    } finally { await staged.delete(recursive: true); }
  } finally {
    if (work != null) await work.delete(recursive: true);
    cancelLock.dispose();
    if (locked) await lock.unlock();
    try { await lock.close(); } catch (_) { /* Cancellation can close a waiting lock. */ }
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<Directory> _stableSdk(Directory cache, CancellationToken cancellation) async {
  final remote = (await _run('git', ['ls-remote', '--exit-code', _upstream, 'refs/heads/stable'],
    cache.path, cancellation, capture: true)).trim();
  final match = RegExp(r'^([0-9a-f]{40})\s+refs/heads/stable$').firstMatch(remote);
  if (match == null) throw StateError('Could not resolve the current upstream Flutter stable revision');
  final revision = match.group(1)!;
  final sdk = Directory('${cache.path}/flutter');
  if (!await sdk.exists()) {
    // Seed immutable Git objects locally. Working-tree changes, including the
    // dev mouse patch, are never copied into this checkout.
    final installed = _installedFlutter();
    final staging = await cache.createTemp('sdk-');
    final candidate = Directory('${staging.path}/flutter');
    try {
      await _run('git', ['clone', '--no-hardlinks', '--no-checkout', installed.path, candidate.path], cache.path, cancellation);
      await _run('git', ['remote', 'set-url', 'origin', _upstream], candidate.path, cancellation);
      await _run('git', ['fetch', '--depth=1', 'origin', 'stable'], candidate.path, cancellation);
      await _run('git', ['checkout', '-B', 'stable', revision], candidate.path, cancellation);
      final installedRevision = (await _run('git', ['rev-parse', 'HEAD'], installed.path, cancellation, capture: true)).trim();
      if (installedRevision == revision && await Directory('${installed.path}/bin/cache').exists()) {
        // APFS copy-on-write keeps engine/Dart downloads separate without another
        // full download. Rebuild Flutter Tools from the pristine release source.
        await _run('/bin/cp', ['-cR', '${installed.path}/bin/cache', '${candidate.path}/bin/cache'], cache.path, cancellation);
        for (final name in ['flutter_tools.snapshot', 'flutter_tools.stamp', 'flutter.version.json']) {
          final file = File('${candidate.path}/bin/cache/$name');
          if (await file.exists()) await file.delete();
        }
      }
      await _requireClean(candidate, cancellation);
      await candidate.rename(sdk.path);
    } finally { await staging.delete(recursive: true); }
  } else {
    await _requireClean(sdk, cancellation);
    final current = (await _run('git', ['rev-parse', 'HEAD'], sdk.path, cancellation, capture: true)).trim();
    if (current != revision) {
      await _run('git', ['fetch', '--depth=1', _upstream, 'stable'], sdk.path, cancellation);
      await _run('git', ['checkout', '-B', 'stable', revision], sdk.path, cancellation);
    }
  }
  await _requireClean(sdk, cancellation);
  return sdk;
}

Directory _installedFlutter() {
  for (final path in (Platform.environment['PATH'] ?? '').split(':')) {
    if (path.isEmpty) continue;
    final executable = File('$path/flutter');
    if (executable.existsSync()) return File(executable.resolveSymbolicLinksSync()).parent.parent;
  }
  throw StateError('Flutter is not on PATH');
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
