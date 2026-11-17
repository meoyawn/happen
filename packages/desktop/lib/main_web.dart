import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;
import 'app.dart';
import 'appearance.dart';
import 'connection.dart';
import 'connection_web.dart' show gatewayUri, serverSocketUri, signInServer, restoreServerSignIn, signOutServers;
import 'database.dart';
import 'machines.dart';
import 'session.dart';
import 'web_login.dart';

void main() {
  web.window.performance.mark('happen-start');
  web.document.documentElement!.setAttribute('data-happen-state', 'opening');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HappenWeb());
  WidgetsBinding.instance.addPostFrameCallback((_) => web.document.getElementById('happen-startup')?.remove());
}

sealed class _AppState { const _AppState(); }
final class _Opening extends _AppState { const _Opening(); }
final class _SignedOut extends _AppState { const _SignedOut([this.error]); final String? error; }
final class _SigningIn extends _AppState { const _SigningIn(); }
final class _Unavailable extends _AppState { const _Unavailable(this.error); final String error; }
final class _Ready extends _AppState {
  const _Ready(this.session, this.machines, this.database);
  final DesktopSession session;
  final MachinesController machines;
  final DesktopDatabase database;
}
final class _Disposed extends _AppState { const _Disposed(); }

_AppState _transition(_AppState current, _AppState next) => switch ((current, next)) {
  (_Opening() || _SigningIn(), _Ready() || _SignedOut() || _Unavailable()) => next,
  (_Unavailable(), _Opening()) => next,
  (_SignedOut(), _SigningIn()) => next,
  (_Ready(), _SignedOut()) => next,
  (_, _Disposed()) when current is! _Disposed => next,
  _ => throw StateError('Invalid web application transition'),
};

class HappenWeb extends StatefulWidget {
  const HappenWeb({super.key});
  @override
  State<HappenWeb> createState() => _HappenWebState();
}

class _HappenWebState extends State<HappenWeb> {
  _AppState _state = const _Opening();
  final _lifetime = CancellationToken();
  String _server = gatewayUri.origin;
  final _navigator = GlobalKey<NavigatorState>();
  CancellationToken? _opening;
  StreamSubscription<Json>? _authorization;

  @override
  void initState() { super.initState(); unawaited(_open()); }
  void _set(_AppState next) {
    if (!mounted) return;
    setState(() => _state = _transition(_state, next));
    final phase = switch (next) { _Ready() => 'ready', _SignedOut() => 'signed-out',
      _Unavailable() => 'unavailable', _SigningIn() => 'signing-in', _ => 'opening' };
    web.document.documentElement!.setAttribute('data-happen-state', phase);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_state, next)) web.window.performance.mark('happen-$phase');
    });
  }

  Future<void> _open({String? key}) async {
    _opening?.cancel();
    final operation = _opening = CancellationToken();
    final token = operation.merge(_lifetime);
    DesktopDatabase? database;
    AgentClient? client;
    DesktopSession? session;
    MachinesController? machines;
    // Auth and the shared SQLite worker can start together. A remembered
    // alternate server cancels this speculative check of the default server.
    final preflightCancellation = CancellationToken();
    final preflight = key == null ? restoreServerSignIn(gatewayUri, token.merge(preflightCancellation))
      .then<Object?>((_) => null, onError: (Object error) => error) : null;
    try {
      database = await openDesktopDatabase('', cancellation: token);
      final saved = jsonObject(await desktopDatabaseRequest(database, 'load', {}, cancellation: token));
      if (key == null) _server = saved['settings']?['default_server'] as String? ?? _server;
      final server = Uri.tryParse(_server.trim());
      if (server == null || server.scheme != 'https' || server.host.isEmpty || server.userInfo.isNotEmpty ||
          server.hasFragment || server.hasQuery || server.path.isNotEmpty && server.path != '/') {
        throw const FormatException('Enter an HTTPS server tunnel URL');
      }
      final alias = 'tunnel-${sha256.convert(utf8.encode(server.origin)).toString().substring(0, 24)}';
      final snapshot = jsonObject(await desktopDatabaseRequest(database, 'load', {'machine': alias}, cancellation: token));
      if (key != null) { await signInServer(server, key, token); }
      else if (server.origin == gatewayUri.origin) {
        final error = await preflight!;
        if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
      } else {
        preflightCancellation.cancel();
        await restoreServerSignIn(server, token);
      }
      _server = server.origin;
      client = await AgentClient.connect(serverSocketUri(server), cancellation: token);
      if (saved['settings']?['default_server'] != server.origin) {
        await desktopDatabaseRequest(database, 'settings.set', {'key': 'default_server', 'value': server.origin}, cancellation: token);
      }
      session = DesktopSession(client, database, attachmentDirectory: 'browser-attachments',
        machineAlias: alias, machineName: server.host);
      await session.restore(snapshot: snapshot);
      machines = MachinesController(session, 'browser');
      token.throwIfCancelled();
      if (!mounted || !identical(_opening, operation)) throw CancelledException();
      final ready = _Ready(session, machines, database);
      session = null; client = null; database = null; machines = null;
      _set(ready);
      _authorization = ready.session.client.events.stream.listen((_) {}, onDone: () {
        if (mounted && identical(_state, ready)) unawaited(_signOut());
      });
      unawaited(ready.session.load());
    } on CancelledException { /* A newer sign-in or app disposal owns startup. */ }
    catch (error) {
      if (mounted && identical(_opening, operation)) {
        if (key == null && !(error is RemoteFailure && error.code == 'unauthorized')) {
          _set(_Unavailable('$error'));
        } else {
          _set(_SignedOut(key == null ? null : '$error'));
        }
      }
    } finally {
      preflightCancellation.cancel();
      if (machines != null) await machines.close();
      if (session != null) { await session.close(); } else { await client?.close(); }
      await database?.close();
    }
  }

  Future<void> _signOut() async {
    final state = _state;
    if (state is! _Ready) return;
    _set(const _SignedOut());
    await _authorization?.cancel(); _authorization = null;
    await state.machines.close();
    await state.session.close();
    await state.database.close();
    await signOutServers(_lifetime);
    _navigator.currentState?.popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    _lifetime.cancel(); _opening?.cancel(); unawaited(_authorization?.cancel());
    final state = _state;
    _state = _transition(state, const _Disposed());
    if (state is _Ready) {
      unawaited(() async { await state.machines.close(); await state.session.close(); await state.database.close(); }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return ListenableBuilder(
      listenable: state is _Ready ? Listenable.merge([state.machines, state.session.appearance]) : const AlwaysStoppedAnimation(0),
      builder: (context, _) => MaterialApp(
        title: 'Happen', navigatorKey: _navigator, debugShowCheckedModeBanner: false,
        theme: desktopTheme(accent: state is _Ready ? state.session.appearance.state.value : desktopDefaultAccent),
        home: state is _Ready ? Stack(children: [
          DesktopView(session: state.machines.active, machines: state.machines, onSignOut: () => unawaited(_signOut())),
          if (MediaQuery.sizeOf(context).width >= 768) Positioned(right: 8, bottom: 8, child: IconButton(tooltip: 'Sign out of Happen',
            icon: const Icon(Icons.logout, size: 16), onPressed: () => unawaited(_signOut()))),
        ]) : Scaffold(body: SafeArea(child: state is _Opening
          ? Center(child: Semantics(label: 'Opening workspace', child: const SizedBox.square(dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2))))
          : state is _Unavailable ? Center(child: Padding(padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Reconnecting to your workspace', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12), Text(state.error), const SizedBox(height: 20),
                FilledButton(onPressed: () { _set(const _Opening()); unawaited(_open()); }, child: const Text('Retry')),
              ])))
          : WebLogin(server: _server, busy: state is _SigningIn,
              error: state is _SignedOut ? state.error : null, submit: _submit))),
      ),
    );
  }

  void _submit(String server, String key) {
    if (_state is! _SignedOut) return;
    _server = server;
    _set(const _SigningIn());
    unawaited(_open(key: key));
  }
}
