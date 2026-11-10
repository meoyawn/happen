// Modified Dart port of Codex apply-patch/lib.rs, 0598a96e9361485f.
// Copyright 2025 OpenAI, Apache-2.0. See ../../../openai/tools/CODEX-LICENSE.
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'diff.dart';

part 'patch_parser.dart';
part 'patch_text.dart';

/// The shared applier commits operations in order, like Codex's standalone tool.
/// The OpenAI adapter also verifies the entire proposal before starting effects.
Future<String> applyPatch(String cwd, String patch, {required CancellationToken cancellation,
  bool verifyBeforeApply = false, String? callId,
  Future<void> Function(String phase, Json item)? onItem,
  Future<void> Function(Json delta)? onPatch}) async {
  cancellation.throwIfCancelled();
  if (utf8.encode(patch).length > 1024 * 1024) throw const FormatException('Patch exceeds 1 MiB');
  final parsed = _parsePatch(patch), hunks = parsed.hunks;
  if (parsed.environment != null) throw StateError('apply_patch environment selection is unavailable for this turn');
  if (hunks.isEmpty) throw StateError('No files were modified.');
  String resolve(String path) => File.fromUri(Directory(cwd).absolute.uri.resolveUri(Uri.file(path)).normalizePath()).path;
  final nativeChanges = <String, dynamic>{};
  if (verifyBeforeApply) {
    for (final hunk in hunks) {
      cancellation.throwIfCancelled();
      final path = resolve(hunk.path);
      if (nativeChanges.containsKey(path)) throw FormatException('invalid patch: multiple operations target $path');
      nativeChanges[path] = switch (hunk) {
        _AddFile(:final content) => {'type': 'add', 'content': content},
        _DeleteFile() => {'type': 'delete', 'content': await _readPatchFile(path, cancellation)},
        _UpdateFile(:final destination, :final chunks) => await () async {
          final original = await _readPatchUpdate(path, cancellation);
          final content = _patchContents(original, path, chunks);
          return {'type': 'update', 'move_path': destination == null ? null : resolve(destination),
            'unified_diff': unifiedDiff(original, content, context: 1)};
        }(),
      };
    }
  }
  final item = <String, dynamic>{'type': 'FileChange', 'id': callId, 'changes': nativeChanges, 'status': null};
  final committed = <Json>[];
  var completed = false, exact = true;
  final affected = <({String kind, String path})>[];
  Future<void> notePath(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false).asCancellable(cancellation);
    if (type != FileSystemEntityType.file && type != FileSystemEntityType.notFound) exact = false;
  }
  Future<String?> optionalText(String path) async {
    await notePath(path);
    try { return await _readPatchFile(path, cancellation); }
    on FileSystemException catch (error) {
      cancellation.throwIfCancelled();
      if (error.osError?.errorCode != 2) exact = false;
      return null;
    } on FormatException {
      exact = false; return null;
    }
  }
  Future<void> write(String path, String content, {bool createParents = false}) async {
    cancellation.throwIfCancelled();
    try {
      try { await File(path).writeAsString(content, flush: true); }
      on FileSystemException catch (error) {
        if (!createParents || error.osError?.errorCode != 2) rethrow;
        await File(path).parent.create(recursive: true);
        cancellation.throwIfCancelled();
        await File(path).writeAsString(content, flush: true);
      }
    } catch (error) {
      exact = false;
      cancellation.throwIfCancelled();
      throw StateError('Failed to write file $path: $error');
    }
  }
  Future<void> remove(String path, String? before, String operation) async {
    cancellation.throwIfCancelled();
    try {
      if (await FileSystemEntity.type(path).asCancellable(cancellation) == FileSystemEntityType.directory) {
        throw FileSystemException('path is a directory', path);
      }
      cancellation.throwIfCancelled();
      await File(path).delete();
    } catch (_) {
      try { if (before == null || await _readPatchFile(path, cancellation) != before) exact = false; }
      catch (_) { exact = false; }
      cancellation.throwIfCancelled();
      throw StateError('$operation $path');
    }
  }
  Json delta(String path, String kind, String? before, String? after, {String? move, String? overwritten}) => {
    'path': path, 'type': kind, 'oldContent': before, 'newContent': after,
    'movePath': move, 'overwrittenMoveContent': overwritten,
  };
  await onItem?.call('started', item);
  try {
    for (final hunk in hunks) {
      cancellation.throwIfCancelled();
      final path = resolve(hunk.path);
      switch (hunk) {
        case _AddFile(:final content):
          final before = await optionalText(path);
          await write(path, content, createParents: true);
          committed.add(delta(path, 'A', before, content));
          nativeChanges[path] = {'type': 'add', 'content': content};
          affected.add((kind: 'A', path: hunk.path));
        case _DeleteFile():
          final before = await optionalText(path);
          if (before == null) exact = false;
          await remove(path, before, 'Failed to delete file');
          if (before != null) committed.add(delta(path, 'D', before, null));
          nativeChanges[path] = {'type': 'delete', 'content': before ?? ''};
          affected.add((kind: 'D', path: hunk.path));
        case _UpdateFile(:final destination, :final chunks):
          await notePath(path);
          final original = await _readPatchUpdate(path, cancellation);
          final content = _patchContents(original, path, chunks);
          final move = destination == null ? null : resolve(destination);
          nativeChanges[path] = {'type': 'update', 'move_path': move,
            'unified_diff': unifiedDiff(original, content, context: 1)};
          if (move == null) {
            await write(path, content);
            committed.add(delta(path, 'M', original, content));
          } else {
            final overwritten = await optionalText(move);
            await write(move, content, createParents: true);
            final index = committed.length;
            // A destination write is already committed even if source removal
            // fails or cancellation arrives between these two filesystem effects.
            committed.add(delta(move, 'A', overwritten, content));
            await remove(path, original, 'Failed to remove original');
            committed[index] = delta(path, 'M', original, content, move: move, overwritten: overwritten);
          }
          affected.add((kind: 'M', path: destination ?? hunk.path));
      }
    }
    completed = true;
    return 'Success. Updated the following files:\n${[
      for (final kind in ['A', 'M', 'D']) for (final change in affected.where((change) => change.kind == kind)) '$kind ${change.path}\n',
    ].join()}';
  } finally {
    try {
      if (committed.isNotEmpty || !exact) await onPatch?.call({'exact': exact, 'changes': committed});
    } finally { await onItem?.call('completed', {...item, 'status': completed ? 'completed' : 'failed'}); }
  }
}

Future<String> _readPatchFile(String path, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final input = ownStream(File(path).openRead(), cancellation);
  try { return await input.stream.transform(utf8.decoder).join().asCancellable(cancellation); }
  finally { await input.close(); }
}

Future<String> _readPatchUpdate(String path, CancellationToken cancellation) async {
  try { return await _readPatchFile(path, cancellation); }
  catch (error) {
    cancellation.throwIfCancelled();
    throw StateError('Failed to read file to update $path: $error');
  }
}
