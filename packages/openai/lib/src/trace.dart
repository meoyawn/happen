import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

/// Opt-in request evidence. Bodies only: never authorization headers or tokens.
/// Each launch gets its own bundle, including when an existing session resumes.
Future<Directory?> startModelTrace(String sessionID, CancellationToken cancellation) async {
  final root = Platform.environment['HAPPEN_ROLLOUT_TRACE_ROOT'];
  if (root == null || root.isEmpty) return null;
  cancellation.throwIfCancelled();
  final directory = Directory('$root/${DateTime.now().toUtc().microsecondsSinceEpoch}-${newId()}');
  await Directory('${directory.path}/payloads').create(recursive: true);
  if (!Platform.isWindows) {
    final process = await Process.start('chmod', ['700', directory.path]);
    final hook = CancellationHook(cancellation, () => process.kill());
    try {
      await Future.wait([process.stdout.drain<void>(), process.stderr.drain<void>()]).asCancellable(cancellation);
      if (await process.exitCode.asCancellable(cancellation) != 0) throw StateError('Could not restrict trace permissions');
    } finally { hook.dispose(); }
  }
  await File('${directory.path}/manifest.json').writeAsString(jsonEncode({
    'schema_version': 1, 'provider': 'openai', 'session_id': sessionID,
  }), flush: true);
  return directory;
}

Future<void> recordModelTrace(Directory? directory, String id, String type, Json body,
  CancellationToken cancellation) async {
  if (directory == null) return;
  cancellation.throwIfCancelled();
  final payload = 'payloads/$id-$type.json';
  await File('${directory.path}/$payload').writeAsString(jsonEncode(body), flush: true);
  cancellation.throwIfCancelled();
  await File('${directory.path}/trace.jsonl').writeAsString('${jsonEncode({
    'id': id, 'type': type, 'payload': payload,
  })}\n', mode: FileMode.append, flush: true);
}
