import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'database.dart';
import 'session.dart';

typedef RemoteMachine = ({String alias, String name, List<String> projects});

sealed class MachineState { const MachineState(); }
final class MachineConnecting extends MachineState { const MachineConnecting(); }
final class MachineReady extends MachineState {
  const MachineReady(this.session);
  final DesktopSession session;
}
final class MachineFailed extends MachineState {
  const MachineFailed(this.error);
  final Object error;
}
final class MachineClosed extends MachineState { const MachineClosed(); }

MachineState _transition(MachineState? current, MachineState next) => switch ((current, next)) {
  (null || MachineFailed() || MachineReady(), MachineConnecting()) => next,
  (MachineConnecting(), MachineReady() || MachineFailed()) => next,
  (null || MachineConnecting() || MachineReady() || MachineFailed(), MachineClosed()) => next,
  _ => throw StateError('Invalid machine transition'),
};

/// Each machine retains its own session, drafts, thread subscriptions and database.
/// Discovering another host never changes the user's active workspace.
class MachinesController extends ChangeNotifier {
  MachinesController(this.local, this.directory) {
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
  DesktopSession get active => switch (_states[_selected]) { MachineReady(:final session) => session, _ => local };
  MachineState? state(String alias) => _states[alias];
  Object? discoveryError;
  Future<void>? _refreshing, _closing;
  Timer? _poll;

  void _set(String alias, MachineState next) {
    _states[alias] = _transition(_states[alias], next);
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (_lifetime.isCancelled) return;
    try {
      final raw = await runIsolateEffect(_readMachines, {}, cancellation: _lifetime);
      _lifetime.throwIfCancelled();
      _hosts = raw.map((host) => (alias: host['alias'] as String, name: host['name'] as String,
        projects: (host['projects'] as List).cast<String>())).toList();
      discoveryError = null;
      notifyListeners();
      // Establish availability using a real initialized protocol connection.
      for (final host in _hosts) {
        final state = _states[host.alias];
        if (state == null || _selected != host.alias &&
            (state is MachineFailed || state is MachineReady && !state.session.connected)) {
          unawaited(connect(host));
        }
      }
    } on CancelledException { /* Window close owns cancellation. */ }
    catch (error) { if (!_lifetime.isCancelled) { discoveryError = error; notifyListeners(); } }
  }

  Future<void> connect(RemoteMachine host) => _pending[host.alias] ??=
    _connect(host).whenComplete(() => _pending.remove(host.alias));

  Future<void> _connect(RemoteMachine host) async {
    final previous = _states[host.alias];
    if (previous is MachineReady && previous.session.connected) return;
    _set(host.alias, const MachineConnecting());
    AgentClient? client;
    IsolateOwner? database;
    DesktopSession? session;
    try {
      if (previous is MachineReady) {
        previous.session.removeListener(notifyListeners);
        await previous.session.close();
      }
      client = await connectSsh(host.alias, cancellation: _lifetime);
      final key = sha256.convert(utf8.encode(host.alias)).toString().substring(0, 24);
      final data = '$directory/remotes/$key';
      database = await openDesktopDatabase(data);
      _lifetime.throwIfCancelled();
      session = DesktopSession(client, database, attachmentDirectory: '$data/attachments');
      await session.load();
      for (final path in host.projects) {
        if (session.projects.any((project) => project.path == path)) continue;
        try { await session.addProject(path); }
        on CancelledException { rethrow; }
        catch (error) { session.showError(error, title: 'Could not open remote project'); }
      }
      _lifetime.throwIfCancelled();
      session.addListener(notifyListeners);
      _set(host.alias, MachineReady(session));
    } catch (error) {
      if (session != null) { await session.close(); }
      else { await client?.close(); await database?.close(); }
      if (!_lifetime.isCancelled) _set(host.alias, MachineFailed(error));
    }
  }

  Future<void> select(String? alias) async {
    if (alias == null) { _selected = null; notifyListeners(); return; }
    final host = hosts.where((host) => host.alias == alias).first;
    await connect(host);
    if (_lifetime.isCancelled) return;
    if (_states[alias] is MachineReady) { _selected = alias; notifyListeners(); }
    else if (_states[alias] case MachineFailed(:final error)) { active.showError(error); }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _poll?.cancel();
    _lifetime.cancel();
    await _refreshing;
    await Future.wait(_pending.values.toList());
    for (final entry in _states.entries.toList()) {
      if (entry.value case MachineReady(:final session)) {
        session.removeListener(notifyListeners);
        await session.close();
      }
      _set(entry.key, const MachineClosed());
    }
    dispose();
  }
}

Future<List<Json>> _readMachines(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final root = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  final file = File('$root/happen/remotes.json');
  if (!await file.exists()) return [];
  cancellation.throwIfCancelled();
  final document = jsonObject(jsonDecode(await file.readAsString()));
  final aliases = <String>{};
  return [for (final raw in document['hosts'] as List? ?? []) (() {
    final host = jsonObject(raw), alias = requiredString(host, 'alias');
    sshOptions(alias);
    if (!aliases.add(alias)) throw FormatException('Duplicate machine alias: $alias');
    return <String, dynamic>{'alias': alias, 'name': host['name'] as String? ?? alias,
      'projects': (host['projects'] as List? ?? []).cast<String>()};
  })()];
}

class MachinePicker extends StatelessWidget {
  const MachinePicker({super.key, required this.machines});
  final MachinesController machines;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: machines, builder: (context, _) {
    final selected = machines.hosts.where((host) => host.alias == machines.selected).firstOrNull;
    return PopupMenuButton<String>(
      tooltip: 'Run threads on',
      onSelected: (value) {
        if (value == 'refresh') { unawaited(machines.refresh()); }
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
