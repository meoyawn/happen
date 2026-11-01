import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

Future<String?> projectBranch(String path, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final deadline = TimeoutCancellationToken(const Duration(seconds: 3));
  final token = cancellation.merge(deadline);
  Process? process;
  CancellationHook? hook;
  try {
    process = await Process.start('git', ['-C', path, 'symbolic-ref', '--quiet', '--short', 'HEAD']);
    hook = CancellationHook(token, () => process?.kill(ProcessSignal.sigkill));
    final output = utf8.decoder.bind(process.stdout).join();
    final errors = process.stderr.drain<void>();
    final code = await process.exitCode;
    final branch = (await output).trim();
    await errors;
    cancellation.throwIfCancelled();
    return !deadline.isCancelled && code == 0 && branch.isNotEmpty ? branch : null;
  } on ProcessException {
    return null;
  } finally {
    hook?.dispose();
    deadline.cancel();
    process?.kill();
  }
}

/// Identity is refreshed when a checkout is opened, selected, or the app resumes.
/// The database's stable checkout key keeps its tasks through identity changes.
Future<String> projectIdentity(
  String path,
  CancellationToken cancellation,
) async {
  cancellation.throwIfCancelled();
  final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
  final token = cancellation.merge(deadline);
  Process? process;
  CancellationHook? hook;
  try {
    process = await Process.start('git', [
      '-C',
      path,
      'config',
      '--local',
      '--get-regexp',
      r'^remote\..*\.url$',
    ]);
    hook = CancellationHook(token, () => process?.kill(ProcessSignal.sigkill));
    final output = utf8.decoder.bind(process.stdout).join();
    final errors = process.stderr.drain<void>();
    final code = await process.exitCode;
    final text = await output;
    await errors;
    token.throwIfCancelled();
    if (code != 0) return path; // A local folder need not be a Git repository.
    final remotes =
        const LineSplitter()
            .convert(text)
            .where((line) => line.contains(' '))
            .toList()
          ..sort((a, b) => a.compareTo(b));
    final remote =
        remotes
            .where((line) => line.startsWith('remote.origin.url '))
            .firstOrNull ??
        remotes.firstOrNull;
    return remote == null
        ? path
        : _remoteIdentity(
            remote.substring(remote.indexOf(' ') + 1).trim(),
            path,
          );
  } on ProcessException {
    // Git may not be installed; local projects remain usable.
    return path;
  } finally {
    hook?.dispose();
    deadline.cancel();
    process?.kill();
  }
}

String _remoteIdentity(String remote, String checkout) {
  if (remote.startsWith('/') || remote.startsWith('.')) {
    return Uri.directory(checkout).resolve(remote).toFilePath();
  }
  // Normalize the common SCP spelling before parsing a URL. Strip credentials,
  // query and fragment; authentication material never becomes a project ID.
  final scp = RegExp(r'^(?:[^/@:]+@)?([^/:]+):(.+)$').firstMatch(remote);
  if (!remote.contains('://') && scp != null) {
    remote = 'ssh://${scp[1]}/${scp[2]}';
  }
  final uri = Uri.tryParse(remote);
  if (uri == null || !uri.hasScheme) {
    return Uri.directory(checkout).resolve(remote).toFilePath();
  }
  if (uri.scheme == 'file') return uri.toFilePath();
  if (!{'http', 'https', 'ssh', 'git'}.contains(uri.scheme) ||
      uri.host.isEmpty) {
    // Custom remote helpers may embed secrets in their opaque arguments.
    return checkout;
  }
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
  final standardPort =
      !uri.hasPort ||
      switch (uri.scheme) {
        'ssh' => uri.port == 22,
        'git' => uri.port == 9418,
        'http' => uri.port == 80,
        'https' => uri.port == 443,
        _ => false,
      };
  return Uri(
    scheme: standardPort ? 'https' : uri.scheme,
    host: uri.host.toLowerCase(),
    port: standardPort ? null : uri.port,
    path: path,
  ).toString();
}
