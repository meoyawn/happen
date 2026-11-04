import 'dart:async';
import 'dart:io';

import 'package:protocol/protocol.dart';

/// Flutter widget tests run offscreen; package contracts use the Dart runner.
Future<void> main() async {
  final cancellation = CancellationToken();
  Process? child;
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  final hook = CancellationHook(cancellation, () => child?.kill(ProcessSignal.sigterm));
  try {
    for (final (executable, arguments) in [
      (Platform.resolvedExecutable, ['test', '--exclude-tags', 'e2e', 'test', 'packages/storage/test', 'packages/server/test', 'packages/agent/test']),
      ('${Directory.current.path}/third_party/flutter/bin/flutter', ['test', '--exclude-tags', 'e2e']),
    ]) {
      cancellation.throwIfCancelled();
      child = await Process.start(executable, arguments,
        workingDirectory: executable == Platform.resolvedExecutable ? null : 'packages/desktop',
        mode: ProcessStartMode.inheritStdio);
      final result = await child.exitCode.asCancellable(cancellation);
      if (result != 0) { exitCode = result; return; }
    }
  } on CancelledException {
    exitCode = 130;
  } finally {
    hook.dispose();
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
  }
}
