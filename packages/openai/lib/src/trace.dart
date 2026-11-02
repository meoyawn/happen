import 'dart:io';

import 'package:protocol/protocol.dart';

/// Opt-in wire evidence, never a reconstruction of the conversation buffer.
Future<Directory?> startRequestDump(CancellationToken cancellation) async {
  final root = Platform.environment['HAPPEN_ROLLOUT_TRACE_ROOT'];
  if (root == null || root.isEmpty) return null;
  cancellation.throwIfCancelled();
  final directory = Directory('$root/${DateTime.now().toUtc().microsecondsSinceEpoch}-${newId()}');
  await directory.create(recursive: true);
  if (!Platform.isWindows) {
    final process = await Process.start('chmod', ['700', directory.path]);
    final hook = CancellationHook(cancellation, () => process.kill());
    try {
      await Future.wait([process.stdout.drain<void>(), process.stderr.drain<void>()]).asCancellable(cancellation);
      if (await process.exitCode.asCancellable(cancellation) != 0) throw StateError('Could not restrict trace permissions');
    } finally { hook.dispose(); }
  }
  return directory;
}

/// The very same serialized JSON is saved and passed to HTTP/WebSocket.
Future<void> dumpRequest(Directory directory, String encoded,
  CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  await File('${directory.path}/${newUuidV7()}.json').writeAsString(encoded, flush: true);
}
