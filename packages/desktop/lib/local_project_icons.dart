import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:config/config.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';

Future<Json> localProjectIcon(String directory, ProjectIcon? icon, {required bool save,
  required CancellationToken cancellation}) => runIsolateEffect(_iconEffect,
    {'directory': directory, 'icon': projectIconConfig(icon), 'save': save}, cancellation: cancellation);

/// Only local project configuration is watched. Workers own every file handle.
Future<void> watchLocalProjectIcons(List<String> directories, {required CancellationToken cancellation,
  required void Function(String, Json) onChange}) async {
  await runIsolateEffect<Json>(_watch, {'directories': directories}, cancellation: cancellation, timeout: null,
    onEvent: (event) => onChange(requiredString(event, 'directory'), jsonObject(event['appearance'])));
}

Future<Json> _watch(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final directories = (params['directories'] as List).cast<String>();
  final readers = {for (final directory in directories) directory: ConfigReader(partialMcp: true)};
  final accepted = <String, Map<String, dynamic>>{}, revisions = <String, String>{};
  var reloads = Future<void>.value();
  void reload() {
    reloads = reloads.then((_) async {
      for (final directory in directories) {
        cancellation.throwIfCancelled();
        Json appearance;
        try {
          final config = await readers[directory]!.load(projectConfigPath(directory), cancellation: cancellation);
          if (identical(accepted[directory], config.values)) continue;
          appearance = await _appearance(directory, parseProjectIcon(config.values['icon']), cancellation);
          accepted[directory] = config.values;
        } on CancelledException { rethrow; }
        catch (error) {
          accepted.remove(directory);
          appearance = _revision({'icon_error': error is FormatException ? error.message
            : 'Could not read the project icon. Check its file path and permissions.'});
        }
        if (revisions[directory] == appearance['icon_revision']) continue;
        revisions[directory] = appearance['icon_revision'] as String;
        cancellation.throwIfCancelled();
        emit({'directory': directory, 'appearance': appearance});
      }
    }).onError<CancelledException>((_, _) {});
  }
  final watcher = ConfigWatcher(directories.map(projectConfigPath), onChange: reload, cancellation: cancellation);
  try {
    reload();
    await CancellableCompleter<void>(cancellation).future;
  } finally { await watcher.close(); await reloads; }
  return {};
}

Future<Json> _iconEffect(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final folder = Directory(requiredString(params, 'directory'));
  if (!folder.isAbsolute || !await folder.exists()) throw const FileSystemException('Choose an existing project folder');
  final directory = await folder.resolveSymbolicLinks();
  cancellation.throwIfCancelled();
  final icon = parseProjectIcon(params['icon']);
  final appearance = await _appearance(directory, icon, cancellation);
  if (params['save'] == true) await saveProjectIcon(directory, icon, cancellation: cancellation);
  return appearance;
}

Json _revision(Json value) => {...value, 'icon_revision': sha256.convert(utf8.encode(jsonEncode({
  ...value, if (value['icon_data'] case final Uint8List bytes) 'icon_data': sha256.convert(bytes).toString(),
}))).toString()};

Future<Json> _appearance(String directory, ProjectIcon? icon, CancellationToken cancellation) async {
  final value = <String, dynamic>{'icon': projectIconConfig(icon)};
  if (icon case ProjectFileIcon(:final path)) {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final expanded = path.startsWith('~/') && home != null ? p.join(home, path.substring(2)) : path;
    final file = File(p.isAbsolute(expanded) ? expanded : p.join(directory, expanded));
    const limit = 8 * 1024 * 1024;
    cancellation.throwIfCancelled();
    if (await file.length() > limit) throw const FormatException('Choose an icon file smaller than 8 MB');
    final bytes = BytesBuilder(copy: false);
    final input = StreamIterator(file.openRead(0, limit + 1));
    try {
      while (await input.moveNext().asCancellable(cancellation, onCancel: () => unawaited(input.cancel()))) {
        bytes.add(input.current);
      }
    } finally { await input.cancel(); }
    cancellation.throwIfCancelled();
    if (bytes.isEmpty) throw const FormatException('The icon file is empty');
    if (bytes.length > limit) throw const FormatException('Choose an icon file smaller than 8 MB');
    value['icon_data'] = bytes.takeBytes();
    value['icon_svg'] = p.extension(file.path).toLowerCase() == '.svg';
  }
  return _revision(value);
}
