import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';

import 'git.dart';

String _absolutePath(String input) {
  final value = input.trim();
  if (value.isEmpty || value.length > 4096 || RegExp(r'[\x00\r\n]').hasMatch(value)) {
    throw const FormatException('Enter a project folder path');
  }
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  final expanded = value == '~' ? home ?? value
    : value.startsWith('~/') || value.startsWith('~\\') ? p.join(home ?? '~', value.substring(2)) : value;
  if (!p.isAbsolute(expanded)) throw const FormatException('Use an absolute path or ~/');
  return p.normalize(expanded);
}

/// Folder completion runs on the selected machine, including for local clients.
Future<Json> browseProjectFolders(String query, CancellationToken cancellation) =>
  runIsolateEffect(_browse, {'query': query}, cancellation: cancellation);

Future<Json> _browse(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final query = requiredString(params, 'query');
  final requested = _absolutePath(query);
  final trailing = query.endsWith('/') || Platform.isWindows && query.endsWith('\\') || query == '~';
  final base = trailing ? requested : p.dirname(requested);
  final prefix = trailing ? '' : p.basename(requested).toLowerCase();
  final folders = <Json>[];
  var truncated = false;
  await for (final entry in Directory(base).list(followLinks: false)) {
    cancellation.throwIfCancelled();
    final name = p.basename(entry.path);
    if (!name.toLowerCase().startsWith(prefix) || name.startsWith('.') && !prefix.startsWith('.')) continue;
    if (entry is! Directory && !(entry is Link && await FileSystemEntity.isDirectory(entry.path))) continue;
    folders.add({'name': name, 'path': entry.path});
    if (folders.length == 200) { truncated = true; break; }
  }
  folders.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
  return {'path': requested, 'directory': base, 'parent': p.dirname(base),
    'separator': p.separator, 'folders': folders, 'truncated': truncated};
}

Future<Json> prepareProjectFolder(Json params, CancellationToken cancellation, {void Function(Json)? onProgress}) =>
  runIsolateEffect(_prepare, params, cancellation: cancellation, onEvent: onProgress,
    timeout: const Duration(minutes: 12));

Future<Json> _prepare(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final kind = requiredString(params, 'kind');
  if (!{'create', 'clone'}.contains(kind)) throw const FormatException('Unknown project source');
  final destination = _absolutePath(requiredString(params, 'path'));
  final source = kind == 'clone' ? requiredString(params, 'remoteUrl').trim() : null;
  if (source != null && (source.startsWith('-') || RegExp(r'[\x00\r\n]').hasMatch(source))) {
    throw const FormatException('Enter a Git repository URL');
  }
  if (await FileSystemEntity.type(destination, followLinks: false) != FileSystemEntityType.notFound) {
    throw const FileSystemException('The destination already exists. Choose a new folder or open it as a local folder.');
  }
  final parent = Directory(p.dirname(destination));
  await parent.create(recursive: true);
  cancellation.throwIfCancelled();
  // Only the private staging directory is removed on failure or cancellation.
  // The requested path appears after Git completes and is never overwritten.
  final staging = await parent.createTemp('.happen-project-');
  try {
    emit({'label': kind == 'clone' ? 'Cloning repository…' : 'Creating repository…'});
    if (source != null) {
      final remote = source.startsWith('~/') || source.startsWith('~\\') ? _absolutePath(source) : source;
      await runGit(parent.path, ['clone', '--progress', '--', remote, staging.path], cancellation,
        write: true, timeout: const Duration(minutes: 10),
        onOutput: (output) => emit({'label': 'Cloning repository…', 'output': output}));
    } else {
      await runGit(staging.path, ['init'], cancellation, write: true);
    }
    cancellation.throwIfCancelled();
    if (await FileSystemEntity.type(destination, followLinks: false) != FileSystemEntityType.notFound) {
      throw const FileSystemException('The destination was created by another operation. Choose another folder.');
    }
    await staging.rename(destination);
    return {'path': destination};
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}
