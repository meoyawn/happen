import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'machine_icons.dart';
import 'remote_connection.dart';
import 'session.dart';
export 'remote_connection.dart' show RemoteMachine;

typedef MachineSession = ({String? alias, String name, DesktopSession session});
typedef ThreadCheckout = ({MachineSession machine, String path, String? branch, bool worktree});
typedef _WorkspaceInventory = ({List<Json> checkouts, bool truncated});

class ThreadWorkspaceCatalog {
  ThreadWorkspaceCatalog(this.repository, List<ThreadCheckout> checkouts, Map<String, String> errors, this.truncated)
    : checkouts = List.unmodifiable(checkouts), errors = Map.unmodifiable(errors);
  final String? repository;
  final List<ThreadCheckout> checkouts;
  final Map<String, String> errors;
  final bool truncated;
}

sealed class _WorkspaceState { const _WorkspaceState(); }
final class _WorkspaceLoading extends _WorkspaceState {
  const _WorkspaceLoading(this.previous);
  final _WorkspaceInventory? previous;
}
final class _WorkspaceReady extends _WorkspaceState {
  const _WorkspaceReady(this.inventory);
  final _WorkspaceInventory inventory;
}
final class _WorkspaceFailed extends _WorkspaceState {
  const _WorkspaceFailed(this.error, this.previous);
  final Object error;
  final _WorkspaceInventory? previous;
}

_WorkspaceInventory? _inventory(_WorkspaceState? state) => switch (state) {
  _WorkspaceReady(:final inventory) => inventory,
  _WorkspaceLoading(:final previous) || _WorkspaceFailed(:final previous) => previous,
  _ => null,
};

_WorkspaceState _workspaceTransition(_WorkspaceState? current, _WorkspaceState next) => switch ((current, next)) {
  (_, _WorkspaceLoading()) => next,
  (_WorkspaceLoading(), _WorkspaceReady() || _WorkspaceFailed()) => next,
  _ => throw StateError('Invalid workspace catalog transition'),
};

bool _sameConnection(RemoteMachine a, RemoteMachine b) =>
  (a.host, a.user, a.port, a.identityFile) == (b.host, b.user, b.port, b.identityFile);

sealed class MachineState { const MachineState(); }
final class MachineConnecting extends MachineState {
  const MachineConnecting([this.previous]);
  final DesktopSession? previous;
}
final class MachineReady extends MachineState {
  const MachineReady(this.session);
  final DesktopSession session;
}
final class MachineFailed extends MachineState {
  const MachineFailed(this.error, [this.previous]);
  final Object error;
  final DesktopSession? previous;
}
final class MachineClosed extends MachineState { const MachineClosed(); }

sealed class RemoteWriteState { const RemoteWriteState(); }
final class RemoteWriteIdle extends RemoteWriteState { const RemoteWriteIdle(); }
final class RemoteWritePending extends RemoteWriteState {
  const RemoteWritePending(this.alias);
  final String alias;
}
final class RemoteWriteSaved extends RemoteWriteState {
  const RemoteWriteSaved(this.alias);
  final String alias;
}
final class RemoteWriteFailed extends RemoteWriteState {
  const RemoteWriteFailed(this.alias, this.error);
  final String alias;
  final Object error;
}

RemoteWriteState _writeTransition(RemoteWriteState current, RemoteWriteState next) => switch ((current, next)) {
  (RemoteWriteIdle() || RemoteWriteSaved() || RemoteWriteFailed(), RemoteWritePending()) => next,
  (RemoteWritePending(), RemoteWriteSaved() || RemoteWriteFailed()) => next,
  _ => throw StateError('Invalid remote settings transition'),
};

MachineState _transition(MachineState? current, MachineState next) => switch ((current, next)) {
  (null || MachineFailed() || MachineReady() || MachineClosed(), MachineConnecting()) => next,
  (MachineConnecting(), MachineConnecting() || MachineReady() || MachineFailed()) => next,
  (null || MachineConnecting() || MachineReady() || MachineFailed(), MachineClosed()) => next,
  _ => throw StateError('Invalid machine transition'),
};

DesktopSession? _cachedSession(MachineState? state) => switch (state) {
  MachineReady(:final session) => session,
  MachineConnecting(:final previous) || MachineFailed(:final previous) => previous,
  _ => null,
};

/// Sessions discover each server's threads; desktop preferences and project
/// references share the local database, scoped by machine.
class MachinesController extends ChangeNotifier {
  MachinesController(this.local, this.directory) {
    local.addListener(_sessionChanged);
    local.sidebarChanges.addListener(_sidebarChanged);
    unawaited(refresh());
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(refresh()));
  }
  final DesktopSession local;
  final String directory;
  final _lifetime = CancellationToken();
  final _states = <String, MachineState>{};
  final _pending = <String, Future<void>>{};
  List<RemoteMachine> _hosts = const [];
  List<RemoteMachine> get hosts => _hosts;
  final _icons = <String, MachineIcon>{};
  Future<void>? _iconsRead;
  MachineIcon iconFor(String? alias) => _icons[alias ?? 'local'] ?? parseMachineIcon(null, remote: alias != null);
  String? _selected;
  late bool _selectionChanged = false;
  DesktopSession get active => _cachedSession(_states[_selected]) ?? local;
  MachineState? state(String alias) => _states[alias];
  List<MachineSession> get sessions => [
    (alias: null, name: 'local', session: local),
    for (final host in hosts)
      if (_cachedSession(_states[host.alias]) case final session?)
        (alias: host.alias, name: host.name, session: session),
  ];
  MachineSession machineFor(DesktopSession session) => sessions.firstWhere((machine) => identical(machine.session, session));

  DesktopSession ownerOf(Project project) => sessions.firstWhere((machine) => machine.session.projects.contains(project)).session;

  void activate(DesktopSession session) {
    final machine = machineFor(session);
    _selectionChanged = true;
    if (_selected == machine.alias) return;
    _selected = machine.alias;
    unawaited(callIsolate(local.database.port, 'settings.set',
      {'key': 'active_machine', 'value': machine.alias ?? ''}, cancellation: _lifetime)
      .catchError((Object error) {
        if (error is! CancelledException) local.showError(error, title: 'Could not save the selected machine');
        return null;
      }));
    notifyListeners();
  }

  void openDraftOn(MachineSession machine, SessionDraft draft) {
    if (!sessions.any((current) => identical(current.session, machine.session)) || !machine.session.connected) {
      throw StateError('The target machine disconnected. Refresh the machine list.');
    }
    machine.session.openDraft(draft);
    activate(machine.session);
  }
  Object? discoveryError;
  Future<void>? _refreshing, _closing;
  Timer? _poll;
  final _connections = <String, CancellationToken>{};
  final _catalogRefreshes = <DesktopSession, Future<void>>{};
  final _retries = <String, Timer>{};
  final _attempts = <String, int>{};
  final _workspaces = <DesktopSession, _WorkspaceState>{};
  final _workspaceSignatures = <DesktopSession, String>{};
  final _workspaceUpdated = <DesktopSession, DateTime>{};
  final _workspaceTokens = <DesktopSession, CancellationToken>{};
  final _workspacePending = <Future<void>>{};
  bool discoveringWorkspaces(DesktopSession session) => session.connected &&
    (_workspaces[session] == null || _workspaces[session] is _WorkspaceLoading);
  RemoteWriteState _writeState = const RemoteWriteIdle();
  RemoteWriteState get writeState => _writeState;
  bool get saving => _writeState is RemoteWritePending;
  void _write(RemoteWriteState next) {
    _writeState = _writeTransition(_writeState, next);
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> chooseIcon(String? alias, MachineIcon icon, {required CancellationToken cancellation}) async {
    final key = alias ?? 'local';
    await (_iconsRead ??= _restoreIcons());
    if (saving) throw StateError('Machine settings are already being saved');
    _write(RemoteWritePending(key));
    try {
      await callIsolate(local.database.port, 'settings.set', {'key': 'machine_icon:$key', 'value': icon.name},
        cancellation: cancellation.merge(_lifetime));
      _lifetime.throwIfCancelled();
      _icons[key] = icon;
      _write(RemoteWriteSaved(key));
    } catch (error) {
      if (!_lifetime.isCancelled) _write(RemoteWriteFailed(key, error));
      rethrow;
    }
  }

  Future<void> _restoreIcons() async {
    final saved = jsonObject(await callIsolate(local.database.port, 'load', {}, cancellation: _lifetime));
    _lifetime.throwIfCancelled();
    final settings = jsonObject(saved['settings']);
    if (!_selectionChanged) {
      final selected = settings['active_machine'] as String?;
      _selected = selected == null || selected.isEmpty ? null : selected;
    }
    _icons.addAll({for (final entry in settings.entries)
      if (entry.key.startsWith('machine_icon:'))
        entry.key.substring('machine_icon:'.length): parseMachineIcon(entry.value as String?, remote: entry.key != 'machine_icon:local')});
  }

  void cancelConnection(String alias) {
    _retries.remove(alias)?.cancel();
    _connections[alias]?.cancel();
  }

  void _sessionChanged() {
    if (_lifetime.isCancelled) return;
    for (final entry in _states.entries.toList()) {
      if (entry.value case MachineConnecting(:final previous?) when previous.connected) {
        _set(entry.key, MachineReady(previous));
        unawaited(_refreshCatalog(previous));
      }
    }
    syncProjectIcons();
    _syncWorkspaces();
    notifyListeners();
  }

  void syncProjectIcons() => local.resolveProjectIcons(sessions.map((machine) => machine.session));

  void _sidebarChanged() {
    if (_lifetime.isCancelled) return;
    syncProjectIcons();
    notifyListeners();
  }

  /// Every connected machine publishes one inventory for all drafts. Opening a
  /// picker only reads these snapshots; it never starts discovery or SSH.
  void _syncWorkspaces({bool force = false}) {
    if (_lifetime.isCancelled) return;
    final subdirectories = <String>{
      for (final machine in sessions)
        for (final project in machine.session.projects)
          if (project.workspace?['subdirectory'] case final String relative) relative,
    }.toList()..sort();
    for (final machine in sessions) {
      final session = machine.session;
      if (!session.connected) { _workspaceTokens.remove(session)?.cancel(); continue; }
      final host = hosts.where((host) => host.alias == machine.alias).firstOrNull;
      final paths = <String>{
        for (final project in session.projects) if (!project.removing) project.path,
        ...?host?.projects,
      }.toList()..sort();
      final signature = jsonEncode([paths, subdirectories]);
      if (!force && _workspaceSignatures[session] == signature &&
          (_workspaceTokens.containsKey(session) || DateTime.now().difference(_workspaceUpdated[session]!) < const Duration(minutes: 1))) continue;
      _workspaceTokens.remove(session)?.cancel();
      final token = _workspaceTokens[session] = CancellationToken();
      _workspaceSignatures[session] = signature;
      _workspaceUpdated[session] = DateTime.now();
      _workspaces[session] = _workspaceTransition(_workspaces[session], _WorkspaceLoading(_inventory(_workspaces[session])));
      final operation = _loadWorkspaces(session, paths, subdirectories, token);
      _workspacePending.add(operation);
      unawaited(operation.whenComplete(() => _workspacePending.remove(operation)));
    }
  }

  Future<void> _loadWorkspaces(DesktopSession session, List<String> paths, List<String> subdirectories, CancellationToken token) async {
    try {
      final result = await session.client.discoverWorkspaces(paths: paths, subdirectories: subdirectories,
        cancellation: token.merge(_lifetime));
      token.throwIfCancelled();
      if (_lifetime.isCancelled || !identical(_workspaceTokens[session], token)) return;
      _workspaces[session] = _workspaceTransition(_workspaces[session], _WorkspaceReady((
        checkouts: List.unmodifiable((result['checkouts'] as List).map(jsonObject)), truncated: result['truncated'] == true)));
    } on CancelledException { /* Superseded inventories cannot publish. */ }
    catch (error) {
      if (!_lifetime.isCancelled && !token.isCancelled && identical(_workspaceTokens[session], token)) {
        _workspaces[session] = _workspaceTransition(_workspaces[session], _WorkspaceFailed(error, _inventory(_workspaces[session])));
      }
    } finally {
      if (identical(_workspaceTokens[session], token)) {
        _workspaceTokens.remove(session);
        _workspaceUpdated[session] = DateTime.now();
        if (!_lifetime.isCancelled) notifyListeners();
      }
      token.cancel();
    }
  }

  ThreadWorkspaceCatalog workspaceCatalog(DesktopSession source, Project project) {
    final original = project.workspace;
    final repository = original?['repository'] as String?, relative = original?['subdirectory'] as String? ?? '';
    final choices = <ThreadCheckout>[], errors = <String, String>{};
    var truncated = false;
    for (final machine in sessions) {
      final session = machine.session, state = _workspaces[machine.session], inventory = _inventory(_workspaces[machine.session]);
      if (!session.connected) errors[machine.name] = 'Reconnecting';
      else if (state is _WorkspaceFailed) errors[machine.name] = '${state.error}';
      truncated |= inventory?.truncated == true;
      final seen = <String>{};
      void add(String path, String? branch, bool worktree) {
        if (seen.add(path)) choices.add((machine: machine, path: path, branch: branch, worktree: worktree));
      }
      if (identical(session, source) && original?['bare'] != true) {
        add(project.path, project.branch, original?['worktree'] == true);
      }
      if (repository == null) continue;
      for (final checkout in [
        for (final saved in session.projects) if (!saved.removing && saved.workspace != null) saved.workspace!,
        ...?inventory?.checkouts,
      ]) {
        if (checkout['repository'] != repository || checkout['bare'] == true || checkout['available'] != true) continue;
        final path = jsonObject(checkout['locations'] ?? {})[relative] as String? ??
          (checkout['subdirectory'] == relative ? checkout['path'] as String? : relative.isEmpty ? checkout['repositoryRoot'] as String? : null);
        if (path != null) add(path, checkout['branch'] as String?, checkout['worktree'] == true);
      }
    }
    choices.sort((a, b) {
      final machine = (a.machine.alias ?? '').compareTo(b.machine.alias ?? '');
      return machine != 0 ? machine : a.path.compareTo(b.path);
    });
    return ThreadWorkspaceCatalog(repository, choices, errors, truncated);
  }

  Future<void> saveRemote(String alias, Json values, {required CancellationToken cancellation}) async {
    if (saving) throw StateError('An SSH server setting is already being saved');
    _write(RemoteWritePending(alias));
    try {
      final remote = remoteMachine({'alias': alias, ...values});
      final before = _hosts.where((host) => host.alias == alias).firstOrNull;
      await callIsolate(local.database.port, 'remotes.save', remoteMachineJson(remote), cancellation: cancellation.merge(_lifetime));
      _write(RemoteWriteSaved(alias));
      _hosts = [..._hosts.where((host) => host.alias != alias), remote];
      if (before == null || !_sameConnection(before, remote)) {
        cancelConnection(alias);
        await _pending[alias];
        final previous = _cachedSession(_states[alias]);
        if (previous != null) await previous.disconnect();
        else if (_states[alias] is MachineConnecting) _set(alias, const MachineClosed());
      }
      await refresh();
      unawaited(connect(remote));
    } catch (error) {
      if (_writeState is RemoteWritePending) _write(RemoteWriteFailed(alias, error));
      rethrow;
    }
  }

  Future<void> removeRemote(String alias, {required CancellationToken cancellation}) async {
    if (saving) throw StateError('An SSH server setting is already being saved');
    _write(RemoteWritePending(alias));
    try {
      await callIsolate(local.database.port, 'remotes.remove', {'alias': alias}, cancellation: cancellation.merge(_lifetime));
      _write(RemoteWriteSaved(alias));
      final cached = _cachedSession(_states[alias]);
      _hosts = _hosts.where((host) => host.alias != alias).toList();
      cancelConnection(alias);
      await _pending[alias];
      if (_selected == alias) activate(local);
      _states.remove(alias);
      notifyListeners();
      cached?.removeListener(_sessionChanged);
      cached?.sidebarChanges.removeListener(_sidebarChanged);
      if (cached != null) _forgetWorkspaces(cached);
      await cached?.close();
      await refresh();
    } catch (error) {
      if (_writeState is RemoteWritePending) _write(RemoteWriteFailed(alias, error));
      rethrow;
    }
  }

  Future<void> refreshCatalogs() async {
    _syncWorkspaces();
    await Future.wait([for (final machine in sessions) if (machine.session.connected) _refreshCatalog(machine.session)]);
  }

  Future<void> _refreshCatalog(DesktopSession session) => _catalogRefreshes[session] ??= (() async {
    if (!session.connected) return;
    final host = hosts.where((host) => host.alias == session.machineAlias).firstOrNull;
    for (final path in host?.projects ?? const <String>[]) {
      if (session.projects.any((project) => project.path == path)) continue;
      await session.addProject(path, discovered: true);
    }
    await session.refreshSessions(cancellation: _lifetime);
  })().catchError((Object error) {
      if (error is! CancelledException && !_lifetime.isCancelled) { session.showError(error, title: 'Could not refresh threads'); }
    }).whenComplete(() { _catalogRefreshes.removeWhere((key, _) => identical(key, session)); });

  void _set(String alias, MachineState next) {
    _states[alias] = _transition(_states[alias], next);
    syncProjectIcons();
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (_lifetime.isCancelled) return;
    try {
      final raw = (await callIsolate(local.database.port, 'remotes.list', {}, cancellation: _lifetime) as List).map(jsonObject);
      await (_iconsRead ??= _restoreIcons());
      _lifetime.throwIfCancelled();
      _hosts = raw.map(remoteMachine).toList();
      for (final host in _hosts) {
        if (_cachedSession(_states[host.alias]) case final session?) session.machineName = host.name;
      }
      discoveryError = null;
      notifyListeners();
      // Establish availability using a real initialized protocol connection.
      for (final host in _hosts) {
        final state = _states[host.alias];
        if (state == null || state is MachineReady && state.session.client.isClosed) {
          unawaited(connect(host));
        }
      }
      unawaited(refreshCatalogs());
    } on CancelledException { /* Window close owns cancellation. */ }
    catch (error) { if (!_lifetime.isCancelled) { discoveryError = error; notifyListeners(); } }
  }

  Future<void> connect(RemoteMachine host) => _pending[host.alias] ??= (() {
    _retries.remove(host.alias)?.cancel();
    final token = _connections[host.alias] = CancellationToken();
    return _connect(host, token.merge(_lifetime)).whenComplete(() {
      _pending.removeWhere((key, _) => key == host.alias); _connections.remove(host.alias); token.cancel();
      if (_states[host.alias] is MachineFailed) _scheduleRetry(host);
    });
  })();

  void _scheduleRetry(RemoteMachine host) {
    final current = hosts.where((current) => current.alias == host.alias).firstOrNull;
    if (_lifetime.isCancelled || current == null || !_sameConnection(current, host) || _retries.containsKey(host.alias)) return;
    final attempt = _attempts.update(host.alias, (value) => (value + 1).clamp(0, 5), ifAbsent: () => 0);
    _retries[host.alias] = Timer(Duration(milliseconds: ((1000 << attempt).clamp(1000, 20000)) + host.alias.hashCode.abs() % 501), () {
      _retries.remove(host.alias);
      final current = hosts.where((current) => current.alias == host.alias).firstOrNull;
      if (!_lifetime.isCancelled && current != null) unawaited(connect(current));
    });
  }

  void _forgetWorkspaces(DesktopSession session) {
    _workspaceTokens.remove(session)?.cancel();
    _workspaces.remove(session);
    _workspaceSignatures.remove(session);
    _workspaceUpdated.remove(session);
  }

  Future<void> _connect(RemoteMachine host, CancellationToken cancellation) async {
    final previous = _cachedSession(_states[host.alias]);
    if (previous != null && !previous.client.isClosed) return;
    _set(host.alias, MachineConnecting(previous));
    AgentClient? client;
    DesktopSession? session;
    CancellationHook? cancel;
    try {
      client = await startSsh(host.host, user: host.user, port: host.port,
        identityFile: host.identityFile, cancellation: cancellation);
      cancel = CancellationHook(cancellation, () => unawaited(client?.close()));
      final key = sha256.convert(utf8.encode(host.alias)).toString().substring(0, 24);
      final data = '$directory/remotes/$key';
      await callIsolate(local.database.port, 'machine.import', {'machine': host.alias}, cancellation: cancellation.merge(_lifetime));
      cancellation.throwIfCancelled();
      session = DesktopSession(client, local.database, attachmentDirectory: '$data/attachments',
        sidebarOwner: local, machineAlias: host.alias, machineName: host.name,
        initiallyConnected: client.isConnected);
      await session.restore();
      await session.adoptSidebarPins();
      cancellation.throwIfCancelled();
      session.addListener(_sessionChanged);
      session.sidebarChanges.addListener(_sidebarChanged);
      session.machineName = hosts.firstWhere((current) => current.alias == host.alias).name;
      _attempts.remove(host.alias);
      _set(host.alias, session.connected ? MachineReady(session) : MachineConnecting(session));
      if (session.connected) unawaited(session.load());
      if (session.connected) unawaited(_refreshCatalog(session));
      _syncWorkspaces();
      previous?.removeListener(_sessionChanged);
      previous?.sidebarChanges.removeListener(_sidebarChanged);
      if (previous != null) {
        _forgetWorkspaces(previous);
        try { await previous.close(); }
        catch (error) { local.showError(error, title: 'Could not release the previous connection'); }
      }
    } catch (error) {
      if (session != null) { await session.close(); }
      else { await client?.close(); }
      final current = hosts.where((current) => current.alias == host.alias).firstOrNull;
      if (!_lifetime.isCancelled && current != null && _sameConnection(current, host)) _set(host.alias, MachineFailed(error, previous));
    } finally { cancel?.dispose(); }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _poll?.cancel();
    _lifetime.cancel();
    for (final retry in _retries.values) { retry.cancel(); }
    _retries.clear();
    local.removeListener(_sessionChanged);
    local.sidebarChanges.removeListener(_sidebarChanged);
    await _refreshing;
    await Future.wait(_pending.values.toList());
    await Future.wait(_catalogRefreshes.values.toList());
    await Future.wait(_workspacePending.toList());
    for (final entry in _states.entries.toList()) {
      if (_cachedSession(entry.value) case final session?) {
        session.removeListener(_sessionChanged);
        session.sidebarChanges.removeListener(_sidebarChanged);
        await session.close();
      }
      _set(entry.key, const MachineClosed());
    }
    dispose();
  }
}
