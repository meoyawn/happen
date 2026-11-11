import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';

import 'machines.dart';
import 'session.dart';

enum ProjectSource { folder, create, git, github }

sealed class AddProjectState { const AddProjectState(); }
final class ProjectMachines extends AddProjectState { const ProjectMachines(); }
final class ProjectSources extends AddProjectState {
  const ProjectSources(this.machine);
  final MachineSession machine;
}
final class ProjectRepository extends AddProjectState {
  const ProjectRepository(this.machine, this.source);
  final MachineSession machine;
  final ProjectSource source;
}
final class ProjectLocation extends AddProjectState {
  const ProjectLocation(this.machine, this.source, {this.remoteUrl});
  final MachineSession machine;
  final ProjectSource source;
  final String? remoteUrl;
}
final class ProjectSaving extends AddProjectState {
  const ProjectSaving(this.location, this.label, [this.output]);
  final ProjectLocation location;
  final String label;
  final String? output;
}
final class ProjectCancelling extends AddProjectState {
  const ProjectCancelling(this.location);
  final ProjectLocation location;
}
final class ProjectSaveFailed extends AddProjectState {
  const ProjectSaveFailed(this.location, this.message, this.preparedPath);
  final ProjectLocation location;
  final String message;
  final String? preparedPath;
}
final class ProjectSaved extends AddProjectState {
  const ProjectSaved(this.machine, this.project);
  final MachineSession machine;
  final Project project;
}
final class ProjectAddClosed extends AddProjectState { const ProjectAddClosed(); }

AddProjectState _transition(AddProjectState current, AddProjectState next) => switch ((current, next)) {
  (ProjectMachines(), ProjectSources()) => next,
  (ProjectSources(), ProjectMachines() || ProjectRepository() || ProjectLocation()) => next,
  (ProjectRepository(), ProjectSources() || ProjectLocation()) => next,
  (ProjectLocation(), ProjectSources() || ProjectRepository() || ProjectSaving()) => next,
  (ProjectSaveFailed(), ProjectLocation() || ProjectSaving()) => next,
  (ProjectSaving(), ProjectSaving() || ProjectCancelling() || ProjectSaveFailed() || ProjectSaved()) => next,
  (ProjectCancelling(), ProjectSaveFailed()) => next,
  (_, ProjectAddClosed()) when current is! ProjectAddClosed => next,
  _ => throw StateError('Invalid add project transition'),
};

sealed class ProjectFolderState { const ProjectFolderState(); }
final class ProjectFoldersIdle extends ProjectFolderState { const ProjectFoldersIdle(); }
final class ProjectFoldersLoading extends ProjectFolderState { const ProjectFoldersLoading(); }
final class ProjectFoldersReady extends ProjectFolderState {
  const ProjectFoldersReady(this.result);
  final Json result;
}
final class ProjectFoldersFailed extends ProjectFolderState {
  const ProjectFoldersFailed(this.message);
  final String message;
}

ProjectFolderState _folderTransition(ProjectFolderState current, ProjectFolderState next) => switch ((current, next)) {
  (_, ProjectFoldersLoading() || ProjectFoldersIdle()) => next,
  (ProjectFoldersLoading(), ProjectFoldersReady() || ProjectFoldersFailed()) => next,
  _ => throw StateError('Invalid folder listing transition'),
};

String projectCloneUrl(String input, ProjectSource source) {
  final value = input.trim();
  if (value.isEmpty || value.startsWith('-') || RegExp(r'[\x00\r\n]').hasMatch(value)) {
    throw const FormatException('Enter a Git repository URL');
  }
  if (RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(value)) {
    final repository = value.endsWith('.git') ? value : '$value.git';
    return 'git@github.com:$repository';
  }
  final uri = Uri.tryParse(value);
  if (uri != null && {'https', 'http', 'ssh', 'git'}.contains(uri.scheme) && uri.host.toLowerCase() == 'github.com') {
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (parts.length < 2) throw const FormatException('Enter a GitHub owner/repository');
    final repository = parts[1].endsWith('.git') ? parts[1] : '${parts[1]}.git';
    return 'git@github.com:${parts[0]}/$repository';
  }
  if (uri != null && {'https', 'http', 'ssh', 'git', 'file'}.contains(uri.scheme) ||
      RegExp(r'^[^\s/@:]+@[^\s/:]+:.+$').hasMatch(value) ||
      value.startsWith('/') || value.startsWith('~/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
    return value;
  }
  throw FormatException(source == ProjectSource.github ? 'Enter owner/repository or a GitHub URL' : 'Enter a Git URL or absolute repository path');
}

String projectCloneName(String url) {
  final leaf = url.split(RegExp(r'[?#]')).first.split(RegExp(r'[/\\:]')).where((part) => part.isNotEmpty).last;
  final name = leaf.endsWith('.git') ? leaf.substring(0, leaf.length - 4) : leaf;
  return name.isEmpty || name == '.' || name == '..' ? 'project' : name;
}

ProjectLocation? projectLocation(AddProjectState state) => switch (state) {
  final ProjectLocation location => location,
  ProjectSaving(:final location) || ProjectCancelling(:final location) || ProjectSaveFailed(:final location) => location,
  _ => null,
};

class AddProjectController extends ChangeNotifier {
  final _lifetime = CancellationToken();
  CancellationToken? _listing, _operation;
  AddProjectState _state = const ProjectMachines();
  AddProjectState get state => _state;
  ProjectFolderState _folders = const ProjectFoldersIdle();
  ProjectFolderState get folders => _folders;
  bool get busy => _state is ProjectSaving || _state is ProjectCancelling;

  void _set(AddProjectState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  void _setFolders(ProjectFolderState next) {
    _folders = _folderTransition(_folders, next);
    notifyListeners();
  }

  void chooseMachine(MachineSession machine) {
    if (!machine.session.connected) return;
    _set(ProjectSources(machine));
  }

  void chooseSource(ProjectSource source) {
    if (_state case ProjectSources(:final machine)) {
      _set(source == ProjectSource.folder || source == ProjectSource.create
        ? ProjectLocation(machine, source) : ProjectRepository(machine, source));
    }
  }

  void repository(String value) {
    if (_state case ProjectRepository(:final machine, :final source)) {
      _set(ProjectLocation(machine, source, remoteUrl: projectCloneUrl(value, source)));
    }
  }

  void back() {
    if (busy) return;
    _listing?.cancel();
    _setFolders(const ProjectFoldersIdle());
    final next = switch (_state) {
      ProjectSources() => const ProjectMachines(),
      ProjectRepository(:final machine) => ProjectSources(machine),
      ProjectLocation(:final machine, :final source) => source == ProjectSource.folder || source == ProjectSource.create
        ? ProjectSources(machine) : ProjectRepository(machine, source),
      ProjectSaveFailed(:final location) => location,
      _ => null,
    };
    if (next != null) _set(next);
  }

  void editLocation() {
    if (_state case ProjectSaveFailed(:final location, preparedPath: null)) _set(location);
  }

  Future<void> browse(String query) async {
    final location = projectLocation(_state);
    _listing?.cancel();
    if (location == null || busy) return;
    if (query.trim().isEmpty) { _setFolders(const ProjectFoldersIdle()); return; }
    final token = _listing = CancellationToken();
    _setFolders(const ProjectFoldersLoading());
    try {
      final result = await location.machine.session.client.browseProjectFolders(query,
        cancellation: token.merge(_lifetime));
      if (!token.isCancelled && !_lifetime.isCancelled) _setFolders(ProjectFoldersReady(result));
    } on CancelledException { /* A newer query or navigation owns the listing. */ }
    catch (error) {
      if (!token.isCancelled && !_lifetime.isCancelled) _setFolders(ProjectFoldersFailed('$error'));
    }
  }

  Future<void> submit(String path) async {
    final location = projectLocation(_state);
    if (location == null || busy || path.trim().isEmpty) return;
    var prepared = switch (_state) { ProjectSaveFailed(:final preparedPath) => preparedPath, _ => null };
    final token = _operation = CancellationToken();
    final cancellation = token.merge(_lifetime);
    final operationId = newId();
    _listing?.cancel();
    final target = location.machine.session;
    _set(ProjectSaving(location, prepared == null ? 'Preparing project…' : 'Saving project…'));
    final progress = target.client.events.stream.listen((event) {
      if (event['method'] != 'workspace.progress' || event['params']?['operationId'] != operationId ||
          token.isCancelled || _lifetime.isCancelled || _state is! ProjectSaving) { return; }
      final params = jsonObject(event['params']);
      _set(ProjectSaving(location, params['label'] as String, params['output'] as String?));
    });
    try {
      if (!target.connected) { throw StateError('The selected machine is disconnected'); }
      if (prepared == null && location.source != ProjectSource.folder) {
        final result = await target.client.prepareProjectFolder(
          location.source == ProjectSource.create ? 'create' : 'clone', path.trim(),
          remoteUrl: location.remoteUrl, operationId: operationId, cancellation: cancellation);
        prepared = requiredString(result, 'path');
      }
      cancellation.throwIfCancelled();
      _set(ProjectSaving(location, 'Saving project…'));
      final project = await target.ensureProject(prepared ?? path.trim(), cancellation: cancellation);
      cancellation.throwIfCancelled();
      _set(ProjectSaved(location.machine, project));
    } on CancelledException {
      if (!_lifetime.isCancelled) {
        _set(ProjectSaveFailed(location,
          prepared == null ? 'Cancelled.' : 'The folder is ready. Add it to Happen to continue.', prepared));
      }
    } catch (error) {
      if (!_lifetime.isCancelled) _set(ProjectSaveFailed(location, '$error', prepared));
    } finally {
      await progress.cancel();
      if (identical(_operation, token)) { _operation = null; }
      token.cancel();
    }
  }

  void cancel() {
    if (_state case ProjectSaving(:final location)) {
      _set(ProjectCancelling(location));
      _operation?.cancel();
    }
  }

  @override
  void dispose() {
    _lifetime.cancel();
    _listing?.cancel();
    _operation?.cancel();
    _state = _transition(_state, const ProjectAddClosed());
    super.dispose();
  }
}
