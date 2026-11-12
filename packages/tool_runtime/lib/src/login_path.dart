import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:protocol/protocol.dart';

import 'shell.dart';

/// Capture the account's login PATH for child processes launched by a GUI app.
/// The shell, rather than a list of package-manager prefixes, owns tool setup.
/// The bounded capture falls back to the inherited PATH when startup fails.
Future<String?> loginShellPath(String directory, CancellationToken cancellation) async {
  final inherited = Platform.environment['PATH'];
  if (!Platform.isMacOS) return inherited;
  final selected = Platform.environment['SHELL'];
  final shells = <String>{
    if (selected != null && selected.startsWith('/') && File(selected).existsSync()) selected,
    codexShell(),
  };
  for (final shell in shells) {
    cancellation.throwIfCancelled();
    final path = await _capturePath(shell, directory, cancellation);
    if (path != null && path.isNotEmpty) return path;
  }
  return inherited;
}

Future<String?> _capturePath(String shell, String directory, CancellationToken cancellation) async {
  Process? process;
  CancellationHook? hook;
  try {
    process = await Process.start(shell, ['-l', '-c', '/usr/bin/env -0'],
      workingDirectory: directory);
    final child = process;
    hook = CancellationHook(cancellation, () => child.kill(ProcessSignal.sigterm));
    final output = await Future.wait<Object>([
      child.stdout.fold<BytesBuilder>(BytesBuilder(copy: false), (buffer, bytes) {
        if (buffer.length + bytes.length > 512 * 1024) {
          throw const FormatException('Login shell environment exceeds 512 KiB');
        }
        return buffer..add(bytes);
      }),
      child.stderr.drain<void>().then<Object>((_) => 0),
      child.exitCode,
    ]).timeout(const Duration(seconds: 10)).asCancellable(cancellation);
    if (output[2] != 0) return null;
    final records = latin1.decode((output[0] as BytesBuilder).takeBytes()).split('\u0000');
    for (final record in records) {
      if (record.startsWith('PATH=')) {
        final path = utf8.decode(latin1.encode(record.substring(5)));
        if (path.isNotEmpty && !path.contains('\n')) return path;
      }
    }
  } on CancelledException { rethrow;
  } on ProcessException { /* Fall back to the inherited environment. */
  } on FileSystemException { /* Shell startup is unavailable. */
  } on TimeoutException { /* A login profile must not block MCP startup. */
  } on FormatException { /* Malformed or oversized shell output. */
  } finally {
    hook?.dispose();
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try { await process.exitCode.timeout(const Duration(seconds: 2)); }
      on TimeoutException { process.kill(ProcessSignal.sigkill); }
    }
  }
  return null;
}
