import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'app.dart';
import 'appearance.dart';
import 'database.dart';
import 'lifecycle.dart';
import 'local_task_sleep.dart';
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
  AgentServer? _server;
  IsolateOwner? _database;
  AgentClient? _client;
  DesktopSession? _session;
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
  }

  Future<void> _refreshProjects() async {
    try {
      await _session?.refreshProjects();
      await _session?.refreshProviders();
    } on CancelledException {
      // Application exit owns cancellation.
    } catch (error) {
      _session?.showError(error);
    }
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
      await session.load();
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

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Happen',
    builder: (context, child) => DesktopLifecycle(
      onQuit: _close,
      onResume: () => unawaited(_refreshProjects()),
      hasActiveLocalTasks: (_server?.activeTaskCount ?? 0) > 0,
      child: child!,
    ),
    debugShowCheckedModeBanner: false,
    theme: desktopTheme(),
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
        : DesktopView(session: _session!),
  );
}
