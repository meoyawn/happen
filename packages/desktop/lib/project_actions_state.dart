import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';

typedef ProjectScript = ({String id, String name, String command});
typedef ProjectActions = ({String opener, List<ProjectScript> scripts});
typedef ProjectOpener = ({String id, String label, String? application, String? executable});

const _empty = (opener: 'files', scripts: <ProjectScript>[]);
const fileManagerOpener = (id: 'files', label: 'Files', application: null, executable: null);

sealed class ProjectActionsState {
  const ProjectActionsState(this.value);
  final ProjectActions value;
}
final class ProjectActionsLoading extends ProjectActionsState { const ProjectActionsLoading() : super(_empty); }
final class ProjectActionsReady extends ProjectActionsState { const ProjectActionsReady(super.value); }
final class ProjectActionsSaving extends ProjectActionsState {
  const ProjectActionsSaving(super.value, this.pending);
  final ProjectActions pending;
}
final class ProjectActionsFailed extends ProjectActionsState {
  const ProjectActionsFailed(super.value, this.message);
  final String message;
}

ProjectActionsState _transition(ProjectActionsState current, ProjectActionsState next) => switch ((current, next)) {
  (ProjectActionsLoading(), ProjectActionsReady() || ProjectActionsFailed()) => next,
  (ProjectActionsReady() || ProjectActionsFailed(), ProjectActionsSaving()) => next,
  (ProjectActionsSaving(), ProjectActionsReady() || ProjectActionsFailed()) => next,
  _ => throw StateError('Invalid project actions transition'),
};

/// Durable project preferences are acknowledged only after the storage write.
class ProjectActionsController extends ChangeNotifier {
  ProjectActionsController(this.database, this.checkout, this.directory, {required this.local, this.machineAlias});
  final IsolateOwner database;
  final String? machineAlias;
  final String checkout, directory;
  final bool local;
  final _lifetime = CancellationToken();
  ProjectActionsState _state = const ProjectActionsLoading();
  ProjectActionsState get state => _state;
  List<ProjectOpener> _openers = const [fileManagerOpener];
  List<ProjectOpener> get openers => _openers;
  bool _loading = false;
  ProjectOpener get opener => _openers.where((item) => item.id == _state.value.opener).firstOrNull ?? _openers.first;

  void _set(ProjectActionsState next) {
    if (_lifetime.isCancelled) return;
    _state = _transition(_state, next); notifyListeners();
  }

  Future<void> load() async {
    if (_loading || _state is! ProjectActionsLoading || _lifetime.isCancelled) return;
    _loading = true;
    try {
      _openers = List.unmodifiable(await _availableOpeners(_lifetime));
      final saved = jsonObject(await callIsolate(database.port, 'load', {'machine': machineAlias ?? ''}, cancellation: _lifetime));
      final raw = saved['settings']?['project_actions:$checkout'] as String?;
      final value = raw == null ? <String, dynamic>{} : jsonObject(jsonDecode(raw));
      final scripts = <ProjectScript>[for (final script in value['scripts'] as List? ?? const [])
        (id: requiredString(jsonObject(script), 'id'), name: requiredString(jsonObject(script), 'name'),
          command: requiredString(jsonObject(script), 'command'))];
      _set(ProjectActionsReady((opener: value['opener'] as String? ?? 'files', scripts: List.unmodifiable(scripts))));
    } on CancelledException {
      // The owning session closed.
    } catch (error) { _set(ProjectActionsFailed(_empty, error.toString())); }
  }

  Future<void> save(ProjectActions value, CancellationToken cancellation) async {
    if (_state is ProjectActionsLoading || _state is ProjectActionsSaving) throw StateError('Project settings are busy');
    final previous = _state.value;
    final immutable = (opener: value.opener, scripts: List<ProjectScript>.unmodifiable(value.scripts));
    _set(ProjectActionsSaving(previous, immutable));
    try {
      await callIsolate(database.port, 'settings.set', {'machine': machineAlias ?? '', 'key': 'project_actions:$checkout',
        'value': jsonEncode({'opener': immutable.opener,
          'scripts': [for (final script in immutable.scripts) {'id': script.id, 'name': script.name, 'command': script.command}]})},
        cancellation: cancellation.merge(_lifetime));
      _set(ProjectActionsReady(immutable));
    } catch (error) {
      _set(ProjectActionsFailed(previous, error.toString()));
      rethrow;
    }
  }

  Future<void> open(ProjectOpener target, CancellationToken cancellation) async {
    if (!local) throw StateError('Opening local applications requires a shared filesystem');
    final deadline = TimeoutCancellationToken(const Duration(seconds: 10));
    final token = cancellation.merge(_lifetime).merge(deadline);
    Process? process;
    CancellationHook? hook;
    try {
      token.throwIfCancelled();
      final executable = Platform.isMacOS ? '/usr/bin/open'
        : target.executable ?? (Platform.isWindows ? 'explorer.exe' : 'xdg-open');
      process = await Process.start(executable,
        [if (Platform.isMacOS && target.application != null) ...['-a', target.application!], directory]);
      hook = CancellationHook(token, process.kill);
      final result = await Future.wait<Object?>([
        process.exitCode, process.stdout.drain<Object?>(), process.stderr.drain<Object?>(),
      ]).asCancellable(token);
      if (result.first != 0) throw StateError('Could not open ${target.label}');
    } finally { hook?.dispose(); process?.kill(); deadline.cancel(); }
  }

  Future<void> close() async { _lifetime.cancel(); dispose(); }
}

Future<List<ProjectOpener>> _availableOpeners(CancellationToken cancellation) async {
  final result = <ProjectOpener>[(id: 'files', label: Platform.isMacOS ? 'Finder' : Platform.isWindows ? 'Explorer' : 'Files',
    application: null, executable: null)];
  const apps = [
    (id: 'vscode', label: 'VS Code', app: 'Visual Studio Code', command: 'code'),
    (id: 'cursor', label: 'Cursor', app: 'Cursor', command: 'cursor'),
    (id: 'zed', label: 'Zed', app: 'Zed', command: 'zed'),
    (id: 'windsurf', label: 'Windsurf', app: 'Windsurf', command: 'windsurf'),
    (id: 'xcode', label: 'Xcode', app: 'Xcode', command: 'xed'),
  ];
  for (final app in apps) {
    cancellation.throwIfCancelled();
    if (Platform.isMacOS) {
      for (final base in ['/Applications', '${Platform.environment['HOME']}/Applications']) {
        final path = '$base/${app.app}.app';
        if (await Directory(path).exists()) {
          result.add((id: app.id, label: app.label, application: path, executable: null)); break;
        }
      }
    } else {
      for (final base in (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
        final path = '$base/${app.command}${Platform.isWindows ? '.exe' : ''}';
        if (await File(path).exists()) {
          result.add((id: app.id, label: app.label, application: null, executable: path)); break;
        }
      }
    }
  }
  return result;
}
