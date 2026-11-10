import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

import 'build_server.dart';
import 'build_server/common.dart' show runBuildProcess;

String quoteRemote(String value) => "'${value.replaceAll("'", "'\\''")}'";

// Rsync parses --rsh itself: embedded quotes are doubled, not shell-escaped.
String quoteRsyncShell(String value) => '"${value.replaceAll('"', '""')}"';

Future<void> main(List<String> arguments) async {
  final root = Directory.fromUri(Platform.script).parent.parent;
  final aliases = arguments.where((value) => !value.startsWith('--')).toList();
  final architectures = arguments.where((value) => value.startsWith('--architecture=')).toList();
  if (aliases.length > 1 || architectures.length > 1 ||
      arguments.any((value) => value.startsWith('--') && !{
        '--skip-build', '--from-codex', '--architecture=x64', '--architecture=arm64',
      }.contains(value))) {
    throw ArgumentError('Usage: dart tool/deploy_server.dart [SSH_ALIAS] [--skip-build] [--from-codex] [--architecture=x64|arm64]');
  }
  final saved = aliases.isNotEmpty ? <String, dynamic>{'host': aliases.single}
    : await File('${root.path}/.local/deploy-server.json').exists()
      ? jsonObject(jsonDecode(await File('${root.path}/.local/deploy-server.json').readAsString()))
      : throw StateError('Set the private target in .local/deploy-server.json (host, optional user, port, identityFile), or pass an SSH alias.');
  final host = saved['host'], user = saved['user'], port = saved['port'], identity = saved['identityFile'];
  if (host is! String || !RegExp(r'^[a-zA-Z0-9:][a-zA-Z0-9_.:-]*$').hasMatch(host) ||
      user != null && (user is! String || !RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$').hasMatch(user)) ||
      port != null && (port is! int || port < 1 || port > 65535) ||
      identity != null && (identity is! String || identity.isEmpty || RegExp(r'[\x00\r\n]').hasMatch(identity))) {
    throw const FormatException('Invalid private deployment connection settings');
  }
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  final ssh = ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2',
    '-o', 'StrictHostKeyChecking=yes', '-o', 'UpdateHostKeys=no',
    if (user != null) ...['-l', user as String], if (port != null) ...['-p', '$port'],
    if (identity != null) ...['-i', identity as String, '-o', 'IdentitiesOnly=yes']];
  Future<String> remote(List<String> command) => runBuildProcess('ssh', [...ssh, '--', host, command.map(quoteRemote).join(' ')], cancellation, capture: true);
  try {
    final machine = await remote(['uname', '-m']);
    final architecture = switch (machine) { 'x86_64' => 'x64', 'aarch64' => 'arm64', _ => throw StateError('Unsupported VPS architecture') };
    if (architectures.isNotEmpty && architectures.single != '--architecture=$architecture') {
      throw StateError('The cached build targets another architecture; build and deploy Linux $architecture instead.');
    }
    if (!arguments.contains('--skip-build')) await buildServer(root, architecture, cancellation);
    final executable = File('${root.path}/build/server/linux-$architecture/happen-server');
    final checksum = sha256.convert(await executable.readAsBytes()).toString();
    final report = jsonObject(jsonDecode(await File('${executable.parent.path}/build-report.json').readAsString()));
    if (report['target'] != 'ubuntu-24.04-$architecture' || report['sha256'] != checksum ||
        (await File('${executable.path}.sha256').readAsString()).trim() != checksum) {
      throw StateError('The cached server artifact failed integrity or architecture verification; rebuild it before deploying.');
    }
    final home = await remote(['printenv', 'HOME']);
    if (!home.startsWith('/') || home == '/' || RegExp(r'[\x00-\x1f]').hasMatch(home)) throw StateError('Invalid remote home');
    final releases = '$home/.local/share/happen/releases';
    final release = '$releases/$checksum';
    final pending = '$release/pending';
    final current = '$home/.local/share/happen/current';
    final bin = '$home/.local/bin/happen-server';
    final previous = await remote(['readlink', '-m', current]);
    final previousExecutable = await remote(['readlink', '-m', bin]);
    await remote(['mkdir', '-p', pending, '$home/.local/bin']);
    stdout.writeln('Uploading the AOT executable with rsync delta transfer over SSH.');
    final shell = ['ssh', ...ssh, '--'].map(quoteRsyncShell).join(' ');
    final destinationHost = host.contains(':') ? '[$host]' : host;
    await runBuildProcess('rsync', [
      '--checksum', '--times', '--compress', '--partial', '--no-whole-file', '--stats',
      // Relative to releases/<checksum>/pending, with the same source basename.
      if (previous != current) '--copy-dest=../../../current',
      '--rsh=$shell', '--', executable.path, '$destinationHost:${quoteRemote('$pending/')}',
    ], cancellation);
    if ((await remote(['sha256sum', '$pending/happen-server'])).split(' ').first != checksum) throw StateError('Uploaded executable checksum mismatch');
    await remote(['chmod', '755', '$pending/happen-server']);
    await remote(['mv', '-f', '$pending/happen-server', '$release/happen-server']);
    await remote(['rmdir', pending]);
    // The bootstrap extracts and binds every native asset before --version.
    await remote(['$release/happen-server', '--version']);
    if ((await remote(['ldd', '$release/happen-server'])).contains('not found')) throw StateError('The VPS is missing a system library required by the AOT executable');
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
    stdout.writeln('Server ready. Existing desktop connections reconnect automatically.');
  } finally { cancellation.cancel(); for (final signal in signals) { await signal.cancel(); } }
}
