import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

/// OpenCode's title-based export name, bounded for desktop filesystems.
String sessionExportName(String title, String sessionID) {
  final clean = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');
  final name = clean.isEmpty ? sessionID : clean;
  return name.substring(0, name.length.clamp(0, 100));
}

Future<File> saveSessionExport(Json data, {Directory? downloadsDirectory,
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
  final info = jsonObject(data['info']);
  final name = sessionExportName(info['title'] as String? ?? '', info['id'] as String);
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
