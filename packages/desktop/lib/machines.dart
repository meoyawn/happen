import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'database.dart';
import 'remote_connection.dart';
import 'session.dart';
export 'remote_connection.dart' show RemoteMachine;

typedef MachineSession = ({String? alias, String name, DesktopSession session});

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
  (MachineConnecting(), MachineReady() || MachineFailed()) => next,
  (null || MachineConnecting() || MachineReady() || MachineFailed(), MachineClosed()) => next,
  _ => throw StateError('Invalid machine transition'),
};

DesktopSession? _cachedSession(MachineState? state) => switch (state) {
  MachineReady(:final session) => session,
  MachineConnecting(:final previous) || MachineFailed(:final previous) => previous,
  _ => null,
};

/// Sessions cache each server's SQLite catalog. Selecting a machine changes the
/// workspace; every cached source remains in the shared sidebar.
class MachinesController extends ChangeNotifier {
  MachinesController(this.local, this.directory) {
    local.addListener(notifyListeners);
    local.sidebarChanges.addListener(notifyListeners);
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
  String? _selected;
  String? get selected => _selected;
  DesktopSession get active => _cachedSession(_states[_selected]) ?? local;
  MachineState? state(String alias) => _states[alias];
  List<MachineSession> get sessions => [
    (alias: null, name: 'Local machine', session: local),
    for (final host in hosts)
      if (_cachedSession(_states[host.alias]) case final session?)
        (alias: host.alias, name: host.name, session: session),
  ];
  MachineSession machineFor(DesktopSession session) => sessions.firstWhere((machine) => identical(machine.session, session));

  DesktopSession ownerOf(Project project) => sessions.firstWhere((machine) => machine.session.projects.contains(project)).session;

  void activate(DesktopSession session) {
    final machine = machineFor(session);
    if (_selected == machine.alias) return;
    _selected = machine.alias;
    notifyListeners();
  }

  void openDraftOn(MachineSession machine, SessionDraft draft) {
    if (!sessions.any((current) => identical(current.session, machine.session)) || !machine.session.connected) {
      throw StateError('The target machine disconnected. Refresh the machine list.');
    }
    machine.session.openDraft(draft);
    _selected = machine.alias;
    notifyListeners();
  }
  Object? discoveryError;
  Future<void>? _refreshing, _closing;
  Timer? _poll;
  final _connections = <String, CancellationToken>{};
  final _catalogRefreshes = <DesktopSession, Future<void>>{};
  RemoteWriteState _writeState = const RemoteWriteIdle();
  RemoteWriteState get writeState => _writeState;
  bool get saving => _writeState is RemoteWritePending;
  void _write(RemoteWriteState next) {
    _writeState = _writeTransition(_writeState, next);
    if (!_lifetime.isCancelled) notifyListeners();
  }

  void cancelConnection(String alias) => _connections[alias]?.cancel();

  Future<void> saveRemote(String alias, Json values, {required CancellationToken cancellation}) async {
    if (saving) throw StateError('An SSH server setting is already being saved');
    _write(RemoteWritePending(alias));
    try {
      final remote = remoteMachine({'alias': alias, ...values});
      await callIsolate(local.database.port, 'remotes.save', remoteMachineJson(remote), cancellation: cancellation.merge(_lifetime));
      _write(RemoteWriteSaved(alias));
      cancelConnection(alias);
      await _pending[alias];
      final previous = _cachedSession(_states[alias]);
      if (previous != null) await previous.disconnect();
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
      cancelConnection(alias);
      await _pending[alias];
      final cached = _cachedSession(_states[alias]);
      if (_selected == alias) _selected = null;
      _states.remove(alias);
      _hosts = _hosts.where((host) => host.alias != alias).toList();
      notifyListeners();
      cached?.removeListener(notifyListeners);
      cached?.sidebarChanges.removeListener(notifyListeners);
      await cached?.close();
      await refresh();
    } catch (error) {
      if (_writeState is RemoteWritePending) _write(RemoteWriteFailed(alias, error));
      rethrow;
    }
  }

  Future<void> refreshCatalogs() async {
    await Future.wait([for (final machine in sessions) if (machine.session.connected) _refreshCatalog(machine.session)]);
  }

  Future<void> _refreshCatalog(DesktopSession session) => _catalogRefreshes[session] ??=
    session.refreshSessions(cancellation: _lifetime).catchError((Object error) {
      if (error is! CancelledException && !_lifetime.isCancelled) { session.showError(error, title: 'Could not refresh threads'); }
    }).whenComplete(() { _catalogRefreshes.removeWhere((key, _) => identical(key, session)); });

  void _set(String alias, MachineState next) {
    _states[alias] = _transition(_states[alias], next);
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (_lifetime.isCancelled) return;
    try {
      final raw = (await callIsolate(local.database.port, 'remotes.list', {}, cancellation: _lifetime) as List).map(jsonObject);
      _lifetime.throwIfCancelled();
      _hosts = raw.map(remoteMachine).toList();
      discoveryError = null;
      notifyListeners();
      // Establish availability using a real initialized protocol connection.
      for (final host in _hosts) {
        final state = _states[host.alias];
        if (state == null || state is MachineReady && !state.session.connected) {
          unawaited(connect(host));
        }
      }
      unawaited(refreshCatalogs());
    } on CancelledException { /* Window close owns cancellation. */ }
    catch (error) { if (!_lifetime.isCancelled) { discoveryError = error; notifyListeners(); } }
  }

  Future<void> connect(RemoteMachine host) => _pending[host.alias] ??= (() {
    final token = _connections[host.alias] = CancellationToken();
    return _connect(host, token.merge(_lifetime)).whenComplete(() {
      _pending.removeWhere((key, _) => key == host.alias); _connections.remove(host.alias); token.cancel();
    });
  })();

  Future<void> _connect(RemoteMachine host, CancellationToken cancellation) async {
    final previous = _cachedSession(_states[host.alias]);
    if (previous?.connected == true) return;
    _set(host.alias, MachineConnecting(previous));
    AgentClient? client;
    IsolateOwner? database;
    DesktopSession? session;
    CancellationHook? cancel;
    try {
      client = await connectSsh(host.host, user: host.user, port: host.port,
        identityFile: host.identityFile, cancellation: cancellation);
      cancel = CancellationHook(cancellation, () => unawaited(client?.close()));
      final key = sha256.convert(utf8.encode(host.alias)).toString().substring(0, 24);
      final data = '$directory/remotes/$key';
      database = await openDesktopDatabase(data);
      cancellation.throwIfCancelled();
      session = DesktopSession(client, database, attachmentDirectory: '$data/attachments',
        sidebarOwner: local, machineAlias: host.alias, machineName: host.name);
      await session.load();
      await session.adoptSidebarPins();
      for (final path in host.projects) {
        if (session.projects.any((project) => project.path == path)) continue;
        try { await session.addProject(path); }
        on CancelledException { rethrow; }
        catch (error) { session.showError(error, title: 'Could not open remote project'); }
      }
      cancellation.throwIfCancelled();
      session.addListener(notifyListeners);
      session.sidebarChanges.addListener(notifyListeners);
      _set(host.alias, MachineReady(session));
      previous?.removeListener(notifyListeners);
      previous?.sidebarChanges.removeListener(notifyListeners);
      if (previous != null) {
        try { await previous.close(); }
        catch (error) { local.showError(error, title: 'Could not release the previous connection'); }
      }
    } catch (error) {
      if (session != null) { await session.close(); }
      else { await client?.close(); await database?.close(); }
      if (!_lifetime.isCancelled) _set(host.alias, MachineFailed(error, previous));
    } finally { cancel?.dispose(); }
  }

  Future<void> select(String? alias) async {
    if (alias == null) { _selected = null; notifyListeners(); return; }
    final host = hosts.where((host) => host.alias == alias).first;
    await connect(host);
    if (_lifetime.isCancelled) return;
    if (_cachedSession(_states[alias]) != null) { _selected = alias; notifyListeners(); }
    else if (_states[alias] case MachineFailed(:final error)) { active.showError(error); }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _poll?.cancel();
    _lifetime.cancel();
    local.removeListener(notifyListeners);
    local.sidebarChanges.removeListener(notifyListeners);
    await _refreshing;
    await Future.wait(_pending.values.toList());
    await Future.wait(_catalogRefreshes.values.toList());
    for (final entry in _states.entries.toList()) {
      if (_cachedSession(entry.value) case final session?) {
        session.removeListener(notifyListeners);
        session.sidebarChanges.removeListener(notifyListeners);
        await session.close();
      }
      _set(entry.key, const MachineClosed());
    }
    dispose();
  }
}

class MachinePicker extends StatelessWidget {
  const MachinePicker({super.key, required this.machines, this.onSettings});
  final MachinesController machines;
  final VoidCallback? onSettings;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: machines, builder: (context, _) {
    final selected = machines.hosts.where((host) => host.alias == machines.selected).firstOrNull;
    return PopupMenuButton<String>(
      tooltip: 'Run threads on',
      onSelected: (value) {
        if (value == 'settings') { onSettings?.call(); }
        else if (value == 'refresh') { unawaited(machines.refresh()); }
        else { unawaited(machines.select(value == 'local' ? null : value)); }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: 'local', checked: selected == null, child: const Text('Local machine')),
        for (final host in machines.hosts) CheckedPopupMenuItem(value: host.alias,
          checked: machines.selected == host.alias,
          enabled: machines.state(host.alias) is! MachineConnecting,
          child: Tooltip(message: switch (machines.state(host.alias)) { MachineFailed(:final error) => '$error', _ => host.alias },
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(host.name), const SizedBox(width: 12),
              Text(switch (machines.state(host.alias)) {
                MachineReady(:final session) => session.connected ? 'Available' : 'Reconnect',
                MachineFailed() => 'Retry connection', _ => 'Connecting…',
              }, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]))),
        const PopupMenuDivider(),
        if (onSettings != null) const PopupMenuItem(value: 'settings', child: Text('Manage servers…')),
        PopupMenuItem(value: 'refresh', child: Text(machines.discoveryError == null ? 'Refresh machines' : 'Discovery failed · retry')),
      ],
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(selected == null ? Icons.computer_outlined : Icons.dns_outlined, size: 15),
        const SizedBox(width: 7),
        Flexible(child: Text(selected?.name ?? 'Local machine', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12))),
        const SizedBox(width: 4), const Icon(Icons.expand_more, size: 15),
      ])),
    );
  });
}
