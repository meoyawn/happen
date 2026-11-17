import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'app.dart';
import 'appearance.dart';
import 'connection.dart';
import 'connection_web.dart' show gatewayUri, serverSocketUri, signInServer, restoreServerSignIn, signOutServers;
import 'database.dart';
import 'machines.dart';
import 'session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HappenWeb());
}

sealed class _AppState { const _AppState(); }
final class _Opening extends _AppState { const _Opening(); }
final class _SignedOut extends _AppState { const _SignedOut([this.error]); final String? error; }
final class _SigningIn extends _AppState { const _SigningIn(); }
final class _Ready extends _AppState {
  const _Ready(this.session, this.machines, this.database);
  final DesktopSession session;
  final MachinesController machines;
  final DesktopDatabase database;
}
final class _Disposed extends _AppState { const _Disposed(); }

_AppState _transition(_AppState current, _AppState next) => switch ((current, next)) {
  (_Opening() || _SigningIn(), _Ready() || _SignedOut()) => next,
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
  final _key = TextEditingController();
  final _server = TextEditingController(text: gatewayUri.origin);
  final _navigator = GlobalKey<NavigatorState>();
  CancellationToken? _opening;
  StreamSubscription<Json>? _authorization;

  @override
  void initState() { super.initState(); unawaited(_open()); }
  void _set(_AppState next) { if (mounted) setState(() => _state = _transition(_state, next)); }

  Future<void> _open({String? key}) async {
    _opening?.cancel();
    final operation = _opening = CancellationToken();
    final token = operation.merge(_lifetime);
    DesktopDatabase? database;
    AgentClient? client;
    DesktopSession? session;
    MachinesController? machines;
    try {
      database = await openDesktopDatabase('', cancellation: token);
      if (key == null) {
        final saved = jsonObject(await desktopDatabaseRequest(database, 'load', {}, cancellation: token));
        _server.text = saved['settings']?['default_server'] as String? ?? _server.text;
      }
      final server = Uri.tryParse(_server.text.trim());
      if (server == null || server.scheme != 'https' || server.host.isEmpty || server.userInfo.isNotEmpty ||
          server.hasFragment || server.hasQuery || server.path.isNotEmpty && server.path != '/') {
        throw const FormatException('Enter an HTTPS server tunnel URL');
      }
      if (key != null && key.isNotEmpty) { await signInServer(server, key, token); }
      else { await restoreServerSignIn(server, token); }
      _key.clear();
      client = await AgentClient.connect(serverSocketUri(server), cancellation: token);
      await desktopDatabaseRequest(database, 'settings.set', {'key': 'default_server', 'value': server.origin}, cancellation: token);
      final alias = 'tunnel-${sha256.convert(utf8.encode(server.origin)).toString().substring(0, 24)}';
      session = DesktopSession(client, database, attachmentDirectory: 'browser-attachments',
        machineAlias: alias, machineName: server.host);
      await session.restore();
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
        _set(_SignedOut(error is RemoteFailure && error.code == 'unauthorized' && key == null ? null : '$error'));
      }
    } finally {
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
    _lifetime.cancel(); _opening?.cancel(); _key.dispose(); _server.dispose(); unawaited(_authorization?.cancel());
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
        ]) : Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(padding: const EdgeInsets.all(28), child: AutofillGroup(child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Happen', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12), const Text('Connect to your server with its owner key.'),
              const SizedBox(height: 24),
              TextField(key: const ValueKey('server-url'), controller: _server, enabled: state is _SignedOut,
                style: const TextStyle(fontSize: 16),
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Server tunnel URL', border: OutlineInputBorder())),
              const SizedBox(height: 16),
              TextField(key: const ValueKey('owner-key'), controller: _key, obscureText: true,
                style: const TextStyle(fontSize: 16),
                enabled: state is _SignedOut, autofocus: true, autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Owner key', border: OutlineInputBorder()),
                onSubmitted: (_) => _submit()),
              const SizedBox(height: 16),
              if (state is _SignedOut && state.error != null) ...[
                Text(state.error!, style: const TextStyle(color: desktopError)), const SizedBox(height: 16),
              ],
              FilledButton(key: const ValueKey('owner-sign-in'), onPressed: state is _SignedOut ? _submit : null,
                child: Text(state is _Opening || state is _SigningIn ? 'Connecting…' : 'Sign in')),
            ],
          )))))))),
      ),
    );
  }

  void _submit() {
    if (_state is! _SignedOut) return;
    final key = _key.text;
    _set(const _SigningIn());
    unawaited(_open(key: key));
  }
}
