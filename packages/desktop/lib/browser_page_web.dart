import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';

import 'browser_preview.dart';
import 'connection.dart';

Uri browserAddress(String input) {
  final value = input.trim();
  if (value.isEmpty || value.toLowerCase() == 'about:blank') return Uri.parse('about:blank');
  final explicit = RegExp(r'^[a-z][a-z\d+.-]*://|^(about|data|javascript|mailto):', caseSensitive: false).hasMatch(value);
  final uri = Uri.tryParse(explicit ? value : 'http://$value');
  if (uri == null || !browserLocationAllowed(uri)) throw const FormatException('Enter an HTTP or HTTPS address');
  return explicit || browserHostIsLocal(uri.host) ? uri : uri.replace(scheme: 'https');
}

bool browserHostIsLocal(String host) => host == 'localhost' || host.endsWith('.localhost') ||
  host == '::1' || host == '0.0.0.0' || RegExp(r'^127(?:\.\d{1,3}){3}$').hasMatch(host);

bool browserLocationAllowed(Uri uri) => uri.userInfo.isEmpty && (
  {'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty && uri.port > 0 && uri.port <= 65535 ||
  uri.toString() == 'about:blank');

sealed class BrowserPageState {
  const BrowserPageState(this.location);
  final Uri? location;
}
final class BrowserDormant extends BrowserPageState { const BrowserDormant(super.location); }
final class BrowserLoading extends BrowserPageState { const BrowserLoading(super.location); }
final class BrowserReady extends BrowserPageState {
  const BrowserReady(super.location, this.frameUrl);
  final Uri? frameUrl;
}
final class BrowserFailed extends BrowserPageState {
  const BrowserFailed(super.location, this.error);
  final String error;
}
final class BrowserClosed extends BrowserPageState { const BrowserClosed() : super(null); }

BrowserPageState _transition(BrowserPageState current, BrowserPageState next) => switch ((current, next)) {
  (_, BrowserLoading() || BrowserReady() || BrowserFailed() || BrowserClosed()) when current is! BrowserClosed => next,
  _ => throw StateError('Invalid browser page transition'),
};

/// Retains the entered address separately from the temporary iframe URL.
class BrowserPage extends ChangeNotifier {
  BrowserPage({String initialUrl = '', bool navigationEnabled = true, bool toolbar = true, String? directory,
      AgentClient? client}) : _preview = client == null ? null : BrowserPreview(client) {
    try { _state = BrowserDormant(initialUrl.isEmpty ? null : browserAddress(initialUrl)); }
    on FormatException catch (error) { _state = BrowserFailed(null, error.message); }
    _connection = client?.events.stream.listen(_connectionChanged);
  }

  final BrowserPreview? _preview;
  final _lifetime = CancellationToken();
  late BrowserPageState _state;
  StreamSubscription<Json>? _connection;
  CancellationToken? _navigation;
  bool _reopenOnConnect = false;
  int _generation = 0;

  BrowserPageState get state => _state;
  Uri? get location => _state.location;
  Uri? get frameUrl => switch (_state) { BrowserReady(:final frameUrl) => frameUrl, _ => null };
  String get title => location?.host ?? '';
  bool get loading => _state is BrowserLoading;
  bool get blank => location == null || location.toString() == 'about:blank';
  String? get error => switch (_state) { BrowserFailed(:final error) => error, _ => null };
  int get generation => _generation;
  Future<List<Json>> Function({required CancellationToken cancellation})? get discoverPorts =>
    _preview?.client.discoverRemoteDevServers;

  void _set(BrowserPageState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> start({required CancellationToken cancellation}) async {
    if (_state is BrowserDormant && !blank) await navigate(location!, cancellation: cancellation);
  }

  Future<void> navigate(Uri uri, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    _lifetime.throwIfCancelled();
    if (!browserLocationAllowed(uri)) throw const FormatException('Enter an HTTP or HTTPS address');
    _navigation?.cancel();
    _reopenOnConnect = false;
    _generation++;
    if (!browserHostIsLocal(uri.host)) {
      _preview?.release();
      _set(BrowserReady(uri, uri.scheme == 'about' ? null : uri));
      return;
    }
    final preview = _preview;
    if (preview == null || !preview.client.isConnected) {
      _reopenOnConnect = preview != null;
      _set(BrowserFailed(uri, 'Connect to Happen Server to preview this dev server.'));
      return;
    }

    final attempt = _navigation = CancellationToken();
    final token = attempt.merge(cancellation).merge(_lifetime);
    _set(BrowserLoading(uri));
    try {
      final url = await preview.open(uri, token);
      token.throwIfCancelled();
      _set(BrowserReady(uri, url));
    } catch (error) {
      if (identical(_navigation, attempt) && !_lifetime.isCancelled && !attempt.isCancelled) {
        preview.release();
        _reopenOnConnect = !preview.client.isConnected;
        _set(BrowserFailed(uri, switch (error) {
          StateError(:final message) => message,
          FormatException(:final message) => message,
          _ => 'Could not open this dev server. Try again.',
        }));
      }
    } finally {
      if (identical(_navigation, attempt)) _navigation = null;
      attempt.cancel();
    }
  }

  void _connectionChanged(Json event) {
    final uri = location;
    if (_lifetime.isCancelled || _state is BrowserDormant || uri == null || !browserHostIsLocal(uri.host)) return;
    if (event['method'] == 'connection/closed' && (_preview?.isOpen == true || loading || _reopenOnConnect)) {
      _preview?.release();
      _navigation?.cancel();
      _reopenOnConnect = true;
      _set(BrowserFailed(uri, 'Reconnecting to Happen Server…'));
    } else if (event['method'] == 'connection/ready' && _reopenOnConnect) {
      unawaited(navigate(uri, cancellation: _lifetime));
    }
  }

  Future<Object> evaluate(String script, {required CancellationToken cancellation}) =>
    throw UnsupportedError('Browser security prevents controlling an embedded website');

  void stop() {
    if (!loading) return;
    _navigation?.cancel();
    _preview?.release();
    _set(BrowserFailed(location, 'Preview loading stopped.'));
  }

  void close() {
    if (_state is BrowserClosed) return;
    _lifetime.cancel();
    unawaited(_connection?.cancel());
    _preview?.release();
    _state = _transition(_state, const BrowserClosed());
    dispose();
  }
}
