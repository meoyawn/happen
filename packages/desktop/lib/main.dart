import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'app.dart';
import 'appearance.dart';
import 'database.dart';
import 'desktop_notifications.dart';
import 'lifecycle.dart';
import 'local_task_sleep.dart';
import 'machines.dart';
import 'panel_state.dart';
import 'session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HappenDesktop());
}

class HappenDesktop extends StatefulWidget {
  const HappenDesktop({super.key});

  @override
  State<HappenDesktop> createState() => _HappenDesktopState();
}

class _HappenDesktopState extends State<HappenDesktop> {
  final _lifetime = CancellationToken();
  final _navigator = GlobalKey<NavigatorState>();
  AgentServer? _server;
  IsolateOwner? _database;
  AgentClient? _client;
  DesktopSession? _session;
  late MachinesController? _machines = null;
  late DesktopSession? _displayedSession = null;
  DesktopNotifications? _notifications;
  LocalTaskSleepInhibitor? _sleep;
  StreamSubscription<int>? _activity;
  String? _error;
  late final Future<void> _opening;
  Future<void>? _closing;

  @override
  void initState() {
    super.initState();
    // Hot reload never re-enters initState: the server, socket, database owner,
    // selections, and composer state live for this application instance.
    _opening = _open();
  }

  void _watchLocalTasks() {
    if (_lifetime.isCancelled || _server == null) return;
    _activity ??= _server!.activeTaskCounts.listen((_) {
      if (mounted && !_lifetime.isCancelled) setState(() {});
    });
    _sleep ??= LocalTaskSleepInhibitor(_server!, onError: (error) {
      _session?.showError(error);
      FlutterError.reportError(FlutterErrorDetails(exception: error, library: 'local task sleep'));
    });
  }

  @override
  void reassemble() {
    super.reassemble();
    _watchLocalTasks();
    _watchMachines();
  }

  void _watchMachines() {
    if (_lifetime.isCancelled || _session == null || _machines != null) return;
    _machines = MachinesController(_session!, File(_session!.attachmentDirectory).parent.path);
    _displayedSession = _session;
    _machines!.addListener(_machineChanged);
  }

  void _machineChanged() {
    if (!mounted || _lifetime.isCancelled || identical(_displayedSession, _machines?.active)) return;
    setState(() => _displayedSession = _machines?.active);
  }

  Future<void> _refreshProjects() async {
    try {
      final session = _machines?.active ?? _session;
      await session?.refreshProjects();
      await session?.refreshProviders();
    } on CancelledException {
      // Application exit owns cancellation.
    } catch (error) {
      _session?.showError(error);
    }
  }

  void _openNotification(DesktopTask target) {
    final session = _session;
    if (session == null || _lifetime.isCancelled) return;
    final parent = target.sideParentID == null ? target : session.projects
      .expand((project) => project.tasks).where((task) => task.id == target.sideParentID).firstOrNull;
    if (parent == null) return;
    final project = session.projects.where((project) => project.tasks.contains(parent)).firstOrNull;
    if (project == null) return;
    unawaited(_machines?.select(null));
    _navigator.currentState?.popUntil((route) => route.isFirst);
    unawaited(() async {
      try {
        await session.select(project, parent);
        if (!_lifetime.isCancelled && parent != target) session.openSessionPanel(parent, sideChatPanel(target.id));
      } on CancelledException {
        // Application exit owns cancellation.
      } catch (error) {
        session.showError(error);
      }
    }());
  }

  Future<void> _open() async {
    try {
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      final directory =
          Platform.environment['AGENT_DATA_DIR'] ??
          (home == null
              ? throw StateError('Set AGENT_DATA_DIR, HOME, or USERPROFILE')
              : '$home/.local/share/agent-server');
      _server = await AgentServer.startEmbedded(directory: directory);
      _lifetime.throwIfCancelled();
      _watchLocalTasks();
      _database = await openDesktopDatabase(directory);
      _lifetime.throwIfCancelled();
      _client = await AgentClient.connect(
        _server!.uri,
        token: _server!.token,
        cancellation: _lifetime,
      );
      _lifetime.throwIfCancelled();
      final session = _session = DesktopSession(_client!, _database!, attachmentDirectory: '$directory/attachments');
      _notifications = DesktopNotifications(session);
      await session.load();
      _watchMachines();
      _lifetime.throwIfCancelled();
      if (mounted) setState(() {});
    } on CancelledException {
      // Quit can cancel startup before all embedded owners are ready.
    } catch (error) {
      _error = error.toString();
      if (mounted) setState(() {});
    }
  }

  Future<void> _close() => _closing ??= _closeOwners();

  Future<void> _closeOwners() async {
    _lifetime.cancel();
    await _opening;
    await _activity?.cancel();
    _machines?.removeListener(_machineChanged);
    await _machines?.close();
    try {
      await _notifications?.close();
    } finally {
      try {
        if (_session case final session?) {
          await session.close();
        } else {
          try {
            await _client?.close();
          } finally {
            await _database?.close();
          }
        }
      } finally {
        try {
          await _server?.close();
        } finally {
          await _sleep?.close();
        }
      }
    }
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_session?.appearance]),
    builder: (context, _) => MaterialApp(
    title: 'Happen',
    navigatorKey: _navigator,
    builder: (context, child) => DesktopLifecycle(
      onQuit: _close,
      onResume: () => unawaited(_refreshProjects()),
      hasActiveLocalTasks: (_server?.activeTaskCount ?? 0) > 0,
      child: child!,
    ),
    debugShowCheckedModeBanner: true,
    theme: desktopTheme(accent: _session?.appearance.state.value ?? desktopDefaultAccent),
    home: _error != null
        ? Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: SelectableText('Could not open Happen\n\n$_error'),
              ),
            ),
          )
        : _session == null
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : DesktopNotificationWindow(notifications: _notifications!, onOpen: _openNotification,
            child: DesktopView(session: _machines?.active ?? _session!,
              machinePicker: _machines == null ? null : MachinePicker(machines: _machines!))),
  ));
}
