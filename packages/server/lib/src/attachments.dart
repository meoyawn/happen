import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

/// Uploads belong to a WebSocket, never to a guessed global identifier. Images
/// are discarded after admission; ordinary uploaded files retain a server path.
class AttachmentUploads {
  AttachmentUploads(this.directory, this.owner);
  final String directory, owner;
  final _uploads = <String, _Upload>{};
  bool _closed = false;

  Future<Object?> handle(String method, Json params) async {
    if (_closed) throw StateError('Attachment connection closed');
    final id = requiredString(params, 'upload_id');
    validateTaskId(id);
    if (method == 'attachments.cancel') {
      await _remove(id);
      return null;
    }
    if (method == 'attachments.begin') {
      if (_uploads.containsKey(id)) throw StateError('Upload already exists');
      if (_uploads.length >= 32) throw StateError('Too many pending uploads');
      final name = requiredString(params, 'name'), type = requiredString(params, 'type');
      if (!{'image', 'file'}.contains(type)) throw const FormatException('Unsupported upload type');
      inputAttachments([{'type': 'file', 'name': name, 'path': '/placeholder'}]);
      final size = params['size'];
      if (size is! int || size < 0 || size > maxImageInputBytes || type == 'image' && size == 0) {
        throw const FormatException('Attachment source exceeds the 1 GiB input limit');
      }
      final upload = _Upload(id, name, type, size, '$directory/staging/$owner/$id/$name');
      _uploads[id] = upload;
      try {
        await upload.run(() async {
          await File(upload.path).parent.create(recursive: true);
          upload.file = await File(upload.path).open(mode: FileMode.write);
        });
      } catch (_) {
        await _remove(id);
        rethrow;
      }
      return {'upload_id': id, 'offset': 0};
    }
    final upload = _uploads[id];
    if (upload == null) throw StateError('Unknown attachment upload');
    if (upload.claimed) throw StateError('Attachment is being submitted');
    if (method == 'attachments.append') {
      if (upload.ready || params['offset'] != upload.received) throw StateError('Unexpected upload offset');
      final encoded = params['data'];
      if (encoded is! String || encoded.length > 4 * ((maxAttachmentChunkBytes + 2) ~/ 3)) {
        throw const FormatException('Upload blocks must be at most 24 MiB (32 MiB base64)');
      }
      final List<int> bytes;
      try { bytes = base64Decode(encoded); } on FormatException {
        throw const FormatException('Invalid upload base64');
      }
      if (bytes.isEmpty || bytes.length > maxAttachmentChunkBytes || upload.received + bytes.length > upload.size) {
        throw const FormatException('Upload exceeds its declared size');
      }
      await upload.run(() async {
        await upload.file!.writeFrom(bytes);
        upload.received += bytes.length;
      });
      return {'upload_id': id, 'offset': upload.received};
    }
    if (method == 'attachments.finish') {
      if (upload.received != upload.size) throw StateError('Attachment upload is incomplete');
      await upload.run(() async {
        await upload.file?.close();
        upload.file = null;
        upload.ready = true;
      });
      return {'type': upload.type, 'name': upload.name, 'upload_id': id};
    }
    throw const FormatException('Unknown attachment operation');
  }

  Future<({List<Json> parts, List<String> ids})> claim(Object? raw) async {
    if (raw == null) return (parts: <Json>[], ids: <String>[]);
    if (raw is! List) throw const FormatException('Attachments must be a list');
    final parts = <Json>[], ids = <String>[];
    try {
      for (final value in raw) {
        final part = jsonObject(value);
        final id = part['upload_id'];
        if (id == null) { parts.add(part); continue; }
        final upload = _uploads[id];
        if (upload == null || !upload.ready || upload.claimed || upload.active != null) {
          throw StateError('Attachment upload is unavailable');
        }
        upload.claimed = true;
        ids.add(upload.id);
        if (upload.type == 'file' && !upload.moved) {
          final target = File('$directory/attachments/$owner-${upload.id}/${upload.name}');
          await target.parent.create(recursive: true);
          await File(upload.path).rename(target.path);
          upload.path = target.path;
          upload.moved = true;
        }
        parts.add({'type': upload.type, 'name': upload.name, 'path': upload.path,
          if (upload.type == 'image') 'detail': part['detail'] ?? 'high'});
      }
      return (parts: parts, ids: ids);
    } catch (_) {
      await release(ids, committed: false);
      rethrow;
    }
  }

  Future<void> release(List<String> ids, {required bool committed}) async {
    for (final id in ids) {
      final upload = _uploads[id];
      if (upload == null) continue;
      upload.claimed = false;
      if (!committed) continue;
      if (upload.type == 'file') {
        _uploads.remove(id); // The accepted message owns this durable path.
      } else {
        await _remove(id);
      }
    }
  }

  Future<void> _remove(String id) async {
    final upload = _uploads.remove(id);
    if (upload == null) return;
    try { await upload.active; } catch (_) { /* Still release partial writes. */ }
    try { await upload.file?.close(); } on FileSystemException { /* Already closed. */ }
    try { await File(upload.path).parent.delete(recursive: true); } on FileSystemException { /* Cleanup can be retried by maintenance. */ }
  }

  Future<void> close() async {
    _closed = true;
    for (final id in _uploads.keys.toList()) { await _remove(id); }
    try { await Directory('$directory/staging/$owner').delete(recursive: true); } on FileSystemException { /* Already removed. */ }
  }
}

class _Upload {
  _Upload(this.id, this.name, this.type, this.size, this.path);
  final String id, name, type;
  final int size;
  String path;
  int received = 0;
  bool ready = false, claimed = false, moved = false;
  RandomAccessFile? file;
  Future<void>? active;

  Future<void> run(Future<void> Function() operation) async {
    if (active != null) throw StateError('Upload operation is already in progress');
    final current = active = operation();
    try { await current; } finally { active = null; }
  }
}
