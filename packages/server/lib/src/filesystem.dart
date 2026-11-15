// Ported from Codex app-server's fs_processor and exec-server's DirectFileSystem.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';

// Base64 and JSON must fit inside the shared 64 MB client frame limit.
const _readLimit = 32 * 1024 * 1024;

String absoluteFileSystemPath(Json params, [String key = 'path']) {
  final path = requiredString(params, key);
  if (!p.isAbsolute(path) || path.length > 4096 || path.contains('\x00')) {
    throw FormatException('$key must be an absolute file path');
  }
  return path;
}

bool _flag(Json params, String key, bool fallback) {
  final value = params[key];
  if (value != null && value is! bool) throw FormatException('$key must be a boolean');
  return value as bool? ?? fallback;
}

/// Paths and effects belong to the execution host, never the desktop's host.
Future<Json> fileSystemRequest(String method, Json params, CancellationToken cancellation) {
  final request = <String, dynamic>{'method': method};
  if (method == 'fs/copy') {
    request['sourcePath'] = absoluteFileSystemPath(params, 'sourcePath');
    request['destinationPath'] = absoluteFileSystemPath(params, 'destinationPath');
    request['recursive'] = _flag(params, 'recursive', false);
  } else {
    request['path'] = absoluteFileSystemPath(params);
    if (method == 'fs/createDirectory' || method == 'fs/remove') request['recursive'] = _flag(params, 'recursive', true);
    if (method == 'fs/remove') request['force'] = _flag(params, 'force', true);
    if (method == 'fs/writeFile') {
      final data = params['dataBase64'];
      if (data is! String) throw const FormatException('fs/writeFile requires valid base64 dataBase64: expected a string');
      request['dataBase64'] = data;
    }
  }
  return runIsolateEffect<Json>(_fileSystemEffect, request, cancellation: cancellation);
}

Future<Json> _fileSystemEffect(Json params, CancellationToken cancellation, void Function(Json) _) async {
  cancellation.throwIfCancelled();
  final method = params['method'] as String;
  if (method == 'fs/copy') {
    final source = params['sourcePath'] as String, destination = params['destinationPath'] as String;
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      if (params['recursive'] != true) throw const FormatException('fs/copy requires recursive: true when sourcePath is a directory');
      final resolvedSource = await Directory(source).resolveSymbolicLinks();
      final resolvedDestination = await _resolveExistingPath(destination, cancellation);
      if (p.equals(resolvedSource, resolvedDestination) || p.isWithin(resolvedSource, resolvedDestination)) {
        throw const FormatException('fs/copy cannot copy a directory to itself or one of its descendants');
      }
    } else if (type != FileSystemEntityType.file && type != FileSystemEntityType.link) {
      throw const FormatException('fs/copy only supports regular files, directories, and symlinks');
    }
    await _copy(source, destination, type, cancellation);
    return {};
  }
  final path = params['path'] as String;
  switch (method) {
    case 'fs/createDirectory':
      if (params['recursive'] == false && await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.notFound) {
        throw FileSystemException('Path already exists', path);
      }
      cancellation.throwIfCancelled();
      await Directory(path).create(recursive: params['recursive'] as bool);
      return {};
    case 'fs/writeFile':
      final data = params['dataBase64'] as String;
      late Uint8List bytes;
      try {
        bytes = base64Decode(data);
        if (base64Encode(bytes) != data) throw const FormatException('Noncanonical base64');
      } on FormatException catch (error) {
        throw FormatException('fs/writeFile requires valid base64 dataBase64: ${error.message}');
      }
      if (bytes.length > _readLimit) throw const FormatException('File exceeds the 32 MB write limit');
      final type = await FileSystemEntity.type(path);
      if (type != FileSystemEntityType.file && type != FileSystemEntityType.notFound) {
        throw FileSystemException('Path is not a regular file', path);
      }
      cancellation.throwIfCancelled();
      final output = await File(path).open(mode: FileMode.write);
      try {
        for (var offset = 0; offset < bytes.length; offset += 64 * 1024) {
          cancellation.throwIfCancelled();
          await output.writeFrom(bytes, offset, (offset + 64 * 1024).clamp(0, bytes.length));
        }
      } finally { await output.close(); }
      return {};
    case 'fs/remove':
      final type = await FileSystemEntity.type(path, followLinks: false);
      cancellation.throwIfCancelled();
      if (type == FileSystemEntityType.notFound) {
        if (params['force'] == true) return {};
        throw FileSystemException('Path is unavailable', path);
      }
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: params['recursive'] as bool);
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else {
        await File(path).delete();
      }
      return {};
  }
  final stat = await FileStat.stat(path);
  cancellation.throwIfCancelled();
  if (stat.type == FileSystemEntityType.notFound) throw FileSystemException('Path is unavailable', path);
  if (method == 'fs/readDirectory') {
    if (stat.type != FileSystemEntityType.directory) throw FileSystemException('Path is not a directory', path);
    final entries = <Json>[];
    final listing = StreamIterator(Directory(path).list(followLinks: false));
    try {
      while (await listing.moveNext().asCancellable(cancellation)) {
        final entry = listing.current;
        final type = await FileSystemEntity.type(entry.path).asCancellable(cancellation);
        // Match Codex: links whose targets have disappeared are omitted.
        if (type == FileSystemEntityType.notFound) continue;
        entries.add({
          'fileName': p.basename(entry.path),
          'isDirectory': type == FileSystemEntityType.directory,
          'isFile': type == FileSystemEntityType.file,
        });
      }
      return {'entries': entries};
    } finally {
      await listing.cancel();
    }
  }
  if (method == 'fs/getMetadata') {
    final type = await FileSystemEntity.type(path, followLinks: false);
    cancellation.throwIfCancelled();
    return {
      'isDirectory': stat.type == FileSystemEntityType.directory,
      'isFile': stat.type == FileSystemEntityType.file,
      'isSymlink': type == FileSystemEntityType.link,
      // Dart does not expose birth time; Codex specifies zero when unavailable.
      'createdAtMs': 0,
      'modifiedAtMs': stat.modified.millisecondsSinceEpoch,
    };
  }
  if (method != 'fs/readFile') throw ArgumentError('Unknown filesystem operation');
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

Future<String> _resolveExistingPath(String path, CancellationToken cancellation) async {
  final suffix = <String>[];
  var existing = p.normalize(path);
  while (await FileSystemEntity.type(existing) == FileSystemEntityType.notFound) {
    cancellation.throwIfCancelled();
    suffix.add(p.basename(existing));
    existing = p.dirname(existing);
  }
  final resolved = await File(existing).resolveSymbolicLinks();
  return p.normalize(p.joinAll([resolved, ...suffix.reversed]));
}

Future<void> _copy(String source, String destination, FileSystemEntityType type, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  if (type == FileSystemEntityType.link) {
    await Link(destination).create(await Link(source).target());
  } else if (type == FileSystemEntityType.file) {
    await File(source).copy(destination);
  } else if (type == FileSystemEntityType.directory) {
    await Directory(destination).create(recursive: true);
    final listing = StreamIterator(Directory(source).list(followLinks: false));
    try {
      while (await listing.moveNext().asCancellable(cancellation)) {
        final entry = listing.current;
        final type = await FileSystemEntity.type(entry.path, followLinks: false).asCancellable(cancellation);
        await _copy(entry.path, p.join(destination, p.basename(entry.path)), type, cancellation);
      }
    } finally { await listing.cancel(); }
  }
  // Codex ignores sockets, pipes and other special files inside directory copies.
}
