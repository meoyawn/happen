import 'dart:async';
import 'dart:io';

import 'package:config/config.dart';
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
          appearance = await projectIconAppearance(directory, parseProjectIcon(config.values['icon']), cancellation);
          accepted[directory] = config.values;
        } on CancelledException { rethrow; }
        catch (error) {
          accepted.remove(directory);
          appearance = projectIconReadError(error);
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
  final appearance = await projectIconAppearance(directory, icon, cancellation);
  if (params['save'] == true) await saveProjectIcon(directory, icon, cancellation: cancellation);
  return appearance;
}
