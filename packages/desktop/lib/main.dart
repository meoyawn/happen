import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'app.dart';
import 'database.dart';
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
  String? _error;
  late final Future<void> _opening;
  late final AppLifecycleListener _lifecycle;
  Future<void>? _closing;

  @override
  void initState() {
    super.initState();
    // Hot reload never re-enters initState: the server, socket, database owner,
    // selections, and composer state live for this application instance.
    _opening = _open();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_refreshProjects()),
      onExitRequested: () async {
        await _close();
        return AppExitResponse.exit;
      },
    );
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
      final home = Platform.environment['HOME'];
      final directory =
          Platform.environment['AGENT_DATA_DIR'] ??
          (home == null
              ? throw StateError('Set AGENT_DATA_DIR or HOME')
              : '$home/.local/share/agent-server');
      _server = await AgentServer.startEmbedded(directory: directory);
      _lifetime.throwIfCancelled();
      _database = await openDesktopDatabase(directory);
      _lifetime.throwIfCancelled();
      _client = await AgentClient.connect(
        _server!.uri,
        cancellation: _lifetime,
      );
      _lifetime.throwIfCancelled();
      final session = _session = DesktopSession(_client!, _database!);
      await session.load();
      _lifetime.throwIfCancelled();
      if (mounted) setState(() {});
    } on CancelledException {
      // The window can close while the embedded owners are starting.
    } catch (error) {
      _error = error.toString();
      if (mounted) setState(() {});
    }
  }

  Future<void> _close() => _closing ??= _closeOwners();

  Future<void> _closeOwners() async {
    _lifetime.cancel();
    await _opening;
    if (_session case final session?) {
      await session.close();
    } else {
      await _client?.close();
      await _database?.close();
    }
    await _server?.close();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Happen',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff325e57),
        surface: const Color(0xfffcfcfa),
      ),
      scaffoldBackgroundColor: const Color(0xfffcfcfa),
      fontFamily: '.AppleSystemUIFont',
      dividerColor: const Color(0xffe5e6e2),
    ),
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
