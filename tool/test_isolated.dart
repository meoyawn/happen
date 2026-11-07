import 'dart:async';
import 'dart:io';

import 'package:protocol/protocol.dart';

// Each check gets the actual dirty source snapshot but its own package graph,
// analyzer-plugin/hook output and test cache. Shared vendored source/SDK trees
// are read-only inputs; no check mutex or shared .dart_tool directory is needed.
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) throw ArgumentError('Provide the Dart command to run in isolation');
  final source = Directory.current.absolute, cancellation = CancellationToken();
  final workspace = await Directory.systemTemp.createTemp('happen-check-');
  final originalHome = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final home = await Directory('${workspace.path}/home').create();
  final environment = <String, String>{
    for (final name in ['PATH', 'PATHEXT', 'SHELL', 'SYSTEMROOT', 'SystemRoot', 'WINDIR', 'COMSPEC', 'TMPDIR', 'TMP', 'TEMP',
      'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'TERM', 'TZ', '__CF_USER_TEXT_ENCODING', 'SDKROOT', 'DEVELOPER_DIR', 'CODEX_SOURCE_DIR'])
      if (Platform.environment[name] case final String value) name: value,
    'HOME': home.path, 'USERPROFILE': home.path,
    'XDG_CONFIG_HOME': '${home.path}/.config', 'XDG_CACHE_HOME': '${home.path}/.cache', 'XDG_DATA_HOME': '${home.path}/.local/share',
    if (Platform.environment['PUB_CACHE'] ?? (originalHome == null ? null : '$originalHome/.pub-cache') case final String cache) 'PUB_CACHE': cache,
    'HAPPEN_TEST_REPORT_ROOT': source.path,
  };
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((s) => s.watch().listen((_) => cancellation.cancel())).toList();
  Process? child;
  final hook = CancellationHook(cancellation, () => child?.kill(ProcessSignal.sigterm));
  Future<int> run(List<String> command, {String? directory}) async {
    cancellation.throwIfCancelled();
    child = await Process.start(command.first, command.skip(1).toList(), workingDirectory: directory ?? workspace.path,
      mode: ProcessStartMode.inheritStdio,
      environment: environment, includeParentEnvironment: false);
    try { return await child!.exitCode.asCancellable(cancellation); }
    finally {
      final owned = child!; owned.kill(ProcessSignal.sigterm);
      try { await owned.exitCode.timeout(const Duration(seconds: 5)); }
      on TimeoutException { owned.kill(ProcessSignal.sigkill); await owned.exitCode; }
      child = null;
    }
  }
  try {
    final paths = await Process.run('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], workingDirectory: source.path);
    if (paths.exitCode != 0) throw StateError('Could not snapshot the checkout: ${paths.stderr}');
    for (final relative in (paths.stdout as String).split('\u0000').where((p) => p.isNotEmpty).toSet()) {
      cancellation.throwIfCancelled();
      final from = '${source.path}/$relative', to = '${workspace.path}/$relative';
      final type = await FileSystemEntity.type(from, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue; // A tracked deletion in the dirty checkout.
      await Directory(to).parent.create(recursive: true);
      if (type == FileSystemEntityType.directory) {
        // Gitlinks: shared SDK and vendored native source inputs.
        await Link(to).create(from);
      } else if (type == FileSystemEntityType.link) {
        await Link(to).create(await Link(from).target());
      } else { await File(from).copy(to); }
    }
    // A few tools consume the workspace's Git root. An independent index/root,
    // not a link to the human's .git directory, keeps that discovery isolated.
    final git = await Process.run('git', ['init', '--quiet', workspace.path],
      environment: environment, includeParentEnvironment: false);
    if (git.exitCode != 0) throw StateError('Could not initialize the isolated workspace');
    stderr.writeln('Isolated check workspace: ${workspace.path}');
    final resolved = await run([Platform.resolvedExecutable, 'pub', 'get', '--offline']);
    if (resolved != 0) { exitCode = resolved; return; }
    final plugin = await run([Platform.resolvedExecutable, 'pub', 'get', '--offline'], directory: '${workspace.path}/tool/happen_lints');
    if (plugin != 0) { exitCode = plugin; return; }
    exitCode = await run([Platform.resolvedExecutable, ...arguments]);
  } on CancelledException { exitCode = 130; }
  catch (_) { exitCode = 1; rethrow; }
  finally {
    hook.dispose(); cancellation.cancel(); for (final signal in signals) { await signal.cancel(); }
    // Keep failures reproducible. Only this newly-created workspace is removed.
    if (exitCode == 0) await workspace.delete(recursive: true);
    else stderr.writeln('Retained failed check workspace: ${workspace.path}');
  }
}
