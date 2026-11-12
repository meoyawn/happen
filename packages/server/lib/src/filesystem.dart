import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';

// Base64 and JSON must fit inside the shared 64 MB client frame limit.
const _readLimit = 32 * 1024 * 1024;

/// Codex app-server filesystem RPCs. Paths belong to this server's host.
Future<Json> fileSystemRequest(String method, Json params, CancellationToken cancellation) {
  final path = requiredString(params, 'path');
  if (!p.isAbsolute(path) || path.length > 4096 || path.contains('\x00')) {
    throw const FormatException('path must be an absolute file path');
  }
  return runIsolateEffect<Json>(_fileSystemEffect, {'method': method, 'path': path}, cancellation: cancellation);
}

Future<Json> _fileSystemEffect(Json params, CancellationToken cancellation, void Function(Json) _) async {
  final path = requiredString(params, 'path');
  cancellation.throwIfCancelled();
  final stat = await FileStat.stat(path);
  cancellation.throwIfCancelled();
  if (stat.type == FileSystemEntityType.notFound) throw FileSystemException('Path is unavailable', path);
  if (params['method'] == 'fs/getMetadata') {
    final type = await FileSystemEntity.type(path, followLinks: false);
    cancellation.throwIfCancelled();
    return {
      'isDirectory': stat.type == FileSystemEntityType.directory,
      'isFile': stat.type == FileSystemEntityType.file,
      'isSymlink': type == FileSystemEntityType.link,
      'createdAtMs': 0,
      'modifiedAtMs': stat.modified.millisecondsSinceEpoch,
      'size': stat.size,
    };
  }
  if (stat.type != FileSystemEntityType.file) throw FileSystemException('Path is not a regular file', path);
  if (stat.size > _readLimit) throw FileSystemException('File exceeds the 32 MB read limit', path);
  final input = await File(path).open();
  try {
    final bytes = BytesBuilder(copy: false);
    while (true) {
      cancellation.throwIfCancelled();
      final chunk = await input.read(64 * 1024);
      cancellation.throwIfCancelled();
      if (chunk.isEmpty) break;
      bytes.add(chunk);
      if (bytes.length > _readLimit) throw FileSystemException('File exceeds the 32 MB read limit', path);
    }
    return {'dataBase64': base64Encode(bytes.takeBytes())};
  } finally {
    await input.close();
  }
}
