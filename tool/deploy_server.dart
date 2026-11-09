import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

import 'build_server.dart';

String quoteRemote(String value) => "'${value.replaceAll("'", "'\\''")}'";

Future<void> main(List<String> arguments) async {
  final alias = arguments.where((value) => !value.startsWith('--')).singleOrNull;
  if (alias == null || !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(alias) ||
      arguments.any((value) => value.startsWith('--') && !{'--skip-build', '--from-codex'}.contains(value))) {
    throw ArgumentError('Usage: dart tool/deploy_server.dart SSH_ALIAS [--skip-build] [--from-codex]');
  }
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  final ssh = ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3', '--', alias];
  Future<String> remote(List<String> command) => deployRun('ssh', [...ssh, command.map(quoteRemote).join(' ')], cancellation, capture: true);
  try {
    final root = Directory.fromUri(Platform.script).parent.parent;
    final machine = await remote(['uname', '-m']);
    final architecture = switch (machine) { 'x86_64' => 'x64', 'aarch64' => 'arm64', _ => throw StateError('Unsupported VPS architecture') };
    if (!arguments.contains('--skip-build')) await buildServer(root, architecture, cancellation);
    final executable = File('${root.path}/build/server/linux-$architecture/happen-server');
    final checksum = sha256.convert(await executable.readAsBytes()).toString();
    final home = await remote(['printenv', 'HOME']);
    if (!home.startsWith('/') || home == '/' || RegExp(r'[\x00-\x1f]').hasMatch(home)) throw StateError('Invalid remote home');
    final releases = '$home/.local/share/happen/releases';
    final release = '$releases/$checksum';
    final current = '$home/.local/share/happen/current';
    final bin = '$home/.local/bin/happen-server';
    await remote(['mkdir', '-p', release, '$home/.local/bin']);
    stdout.writeln('Uploading the single AOT executable over SSH.');
    final upload = await Process.start('ssh', [...ssh, ['dd', 'of=$release/happen-server.pending', 'status=none'].map(quoteRemote).join(' ')]);
    final uploadHook = CancellationHook(cancellation, () => upload.kill());
    try {
      final streams = Future.wait([upload.stdout.drain<void>(), upload.stderr.forEach(stderr.add)]);
      await upload.stdin.addStream(executable.openRead());
      await upload.stdin.close();
      final code = await upload.exitCode;
      await streams;
      cancellation.throwIfCancelled();
      if (code != 0) throw StateError('SSH upload failed ($code)');
    } finally { uploadHook.dispose(); }
    if ((await remote(['sha256sum', '$release/happen-server.pending'])).split(' ').first != checksum) throw StateError('Uploaded executable checksum mismatch');
    await remote(['chmod', '755', '$release/happen-server.pending']);
    await remote(['mv', '-f', '$release/happen-server.pending', '$release/happen-server']);
    // The bootstrap extracts and binds every native asset before --version.
    await remote(['$release/happen-server', '--version']);
    if ((await remote(['ldd', '$release/happen-server'])).contains('not found')) throw StateError('The VPS is missing a system library required by the AOT executable');
    final previous = await remote(['readlink', '-m', current]);
    final previousExecutable = await remote(['readlink', '-m', bin]);
    await remote(['ln', '-sfn', release, '$current.pending']);
    await remote(['mv', '-Tf', '$current.pending', current]);
    await remote(['ln', '-sfn', '$current/happen-server', '$bin.pending']);
    await remote(['mv', '-Tf', '$bin.pending', bin]);
    if (arguments.contains('--from-codex')) await remote([bin, 'login-from-codex']);
    try {
      final restarted = jsonObject(jsonDecode(await remote([bin, 'daemon', 'restart'])));
      if (restarted['status'] != 'restarted') throw StateError('The daemon did not acknowledge restart');
      stdout.writeln('Daemon restarted and ready (PID ${restarted['pid']}).');
    } catch (_) {
      if (previous != current && previous != release) {
        await remote(['ln', '-sfn', previous, '$current.pending']);
        await remote(['mv', '-Tf', '$current.pending', current]);
        await remote(['ln', '-sfn', previousExecutable, '$bin.pending']);
        await remote(['mv', '-Tf', '$bin.pending', bin]);
        await remote([bin, 'daemon', 'restart']);
        stderr.writeln('Restored the previous release after a failed restart.');
      }
      rethrow;
    }
    // This private, durable alias is the desktop discovery source. No credentials
    // or deployment descriptors are generated anywhere in the checkout.
    final localHome = Platform.environment['HOME']!;
    final configRoot = Platform.environment['XDG_CONFIG_HOME'] ?? '$localHome/.config';
    final config = File('$configRoot/happen/remotes.json');
    await config.parent.create(recursive: true);
    final document = await config.exists() ? jsonObject(jsonDecode(await config.readAsString())) : <String, dynamic>{};
    final hosts = (document['hosts'] as List? ?? []).map(jsonObject).toList();
    if (!hosts.any((host) => host['alias'] == alias)) {
      hosts.add({'alias': alias, 'name': alias, 'projects': ['$home/workspace']});
    }
    final pending = File('${config.path}.pending');
    await pending.writeAsString('${const JsonEncoder.withIndent('  ').convert({...document, 'hosts': hosts})}\n', flush: true);
    await Process.run('chmod', ['600', pending.path]);
    await pending.rename(config.path);
    stdout.writeln('Registered $alias for desktop discovery in ${config.path}.');
  } finally { cancellation.cancel(); for (final signal in signals) { await signal.cancel(); } }
}
