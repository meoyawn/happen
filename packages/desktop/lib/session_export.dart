import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:telemetry/telemetry.dart';

/// OpenCode's title-based export name, bounded for desktop filesystems.
String sessionExportName(String title, String sessionID) {
  final clean = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');
  final name = clean.isEmpty ? sessionID : clean;
  return name.substring(0, name.length.clamp(0, 100));
}

Future<File> saveSessionExport(Json data, {required String title, required String sessionID, Directory? downloadsDirectory,
    required CancellationToken cancellation}) async {
  cancellation.throwIfCancelled();
  final encoded = await CancellableIsolate.run(
    () => '${const JsonEncoder.withIndent('  ').convert(data)}\n', cancellation,
    debugName: 'session-export');
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  if (downloadsDirectory == null && (home == null || home.isEmpty)) {
    throw StateError('Could not locate your Downloads folder');
  }
  final directory = downloadsDirectory ?? Directory('$home${Platform.pathSeparator}Downloads');
  await directory.create(recursive: true);
  cancellation.throwIfCancelled();
  final name = sessionExportName(title, sessionID);
  final file = File.fromUri(directory.uri.resolve('$name-${newId().substring(0, 8)}.json'));
  final partial = File('${file.path}.part');
  try {
    // Publish only a complete file. Await the write before cleanup so cancelling
    // an export cannot leave a disk operation recreating its partial file.
    await partial.writeAsString(encoded, flush: true);
    cancellation.throwIfCancelled();
    return await partial.rename(file.path);
  } finally {
    if (await partial.exists()) await partial.delete();
  }
}

/// Freeze each source's sequence boundary, then stream every page into one
/// Chrome Trace Event document. Active spans remain open in this snapshot.
Future<File> saveSessionTrace(AgentClient client, TraceStore desktop, {
  required String title, required String sessionID, Directory? downloadsDirectory,
  required CancellationToken cancellation,
}) async {
  cancellation.throwIfCancelled();
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  if (downloadsDirectory == null && (home == null || home.isEmpty)) {
    throw StateError('Could not locate your Downloads folder');
  }
  final directory = downloadsDirectory ?? Directory('$home${Platform.pathSeparator}Downloads');
  await directory.create(recursive: true);
  final name = sessionExportName('$title-trace', sessionID);
  final file = File.fromUri(directory.uri.resolve('$name-${newId().substring(0, 8)}.json'));
  final partial = File('${file.path}.part');
  final output = partial.openWrite();
  var closed = false;
  try {
    output.write('{"displayTimeUnit":"ms","metadata":${jsonEncode({
      'source': 'Happen', 'sessionID': sessionID,
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'capture': 'snapshot', 'timestamps': 'Unix microseconds; durations use a monotonic clock',
    })},"traceEvents":[');
    output.write(traceProcessMetadata().map(jsonEncode).join(','));
    for (final server in [true, false]) {
      var after = 0;
      int? through;
      while (true) {
        cancellation.throwIfCancelled();
        final page = server ? await client.tracePage(sessionID,
          after: after, through: through, cancellation: cancellation)
          : await desktop.page(sessionID, after: after, through: through, cancellation: cancellation);
        through ??= page['through'] as int;
        after = page['after'] as int;
        final events = page['events'] as List;
        if (events.isNotEmpty) {
          final encoded = await CancellableIsolate.run(() => events.map(jsonEncode).join(','), cancellation);
          output.write(',$encoded');
          await output.flush();
        }
        if (page['done'] == true) break;
      }
    }
    output.write(']}\n');
    await output.flush();
    await output.close();
    closed = true;
    cancellation.throwIfCancelled();
    return await partial.rename(file.path);
  } finally {
    if (!closed) await output.close();
    if (await partial.exists()) await partial.delete();
  }
}
