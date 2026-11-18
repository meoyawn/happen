import 'dart:async';

import 'package:protocol/protocol.dart';

import 'browser_page.dart' show BrowserPage, BrowserDormant, BrowserLoading, BrowserReady, BrowserFailed, BrowserClosed;
import 'browser_preview.dart';
import 'connection.dart' show AgentClient;

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

/// Retains the entered address separately from the temporary iframe URL.
class PlatformBrowserPage extends BrowserPage {
  PlatformBrowserPage({String initialUrl = '', bool navigationEnabled = true, bool toolbar = true, String? directory,
      AgentClient? client}) : _preview = client == null ? null : BrowserPreview(client),
      super.platform(initialUrl, browserAddress) {
    _connection = client?.events.stream.listen(_connectionChanged);
  }

  final BrowserPreview? _preview;
  final _lifetime = CancellationToken();
  StreamSubscription<Json>? _connection;
  CancellationToken? _navigation;
  bool _reopenOnConnect = false;
  int _generation = 0;

  @override
  Uri? get loadAddress => switch (state) {
    BrowserReady(location: final uri?) when uri.scheme != 'about' => _preview?.loadAddress(uri) ?? uri,
    _ => null,
  };
  @override
  String get title => location?.host ?? '';
  @override
  int get generation => _generation;
  @override
  Future<List<Json>> Function({required CancellationToken cancellation})? get discoverPorts =>
    _preview?.client.discoverRemoteDevServers;

  @override
  Future<void> navigate(Uri uri, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    _lifetime.throwIfCancelled();
    if (!browserLocationAllowed(uri)) throw const FormatException('Enter an HTTP or HTTPS address');
    _navigation?.cancel();
    _reopenOnConnect = false;
    _generation++;
    if (!browserHostIsLocal(uri.host)) {
      _preview?.release();
      updateState(BrowserReady(uri));
      return;
    }
    final preview = _preview;
    if (preview == null || !preview.client.isConnected) {
      _reopenOnConnect = preview != null;
      updateState(BrowserFailed(uri, 'Connect to Happen Server to preview this dev server.'));
      return;
    }

    final attempt = _navigation = CancellationToken();
    final token = attempt.merge(cancellation).merge(_lifetime);
    updateState(BrowserLoading(uri));
    try {
      await preview.open(uri, token);
      token.throwIfCancelled();
      updateState(BrowserReady(uri));
    } catch (error) {
      if (identical(_navigation, attempt) && !_lifetime.isCancelled && !attempt.isCancelled) {
        preview.release();
        _reopenOnConnect = !preview.client.isConnected;
        updateState(BrowserFailed(uri, switch (error) {
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
    if (_lifetime.isCancelled || state is BrowserDormant || uri == null || !browserHostIsLocal(uri.host)) return;
    if (event['method'] == 'connection/closed' && (_preview?.isOpen == true || loading || _reopenOnConnect)) {
      _preview?.release();
      _navigation?.cancel();
      _reopenOnConnect = true;
      updateState(BrowserFailed(uri, 'Reconnecting to Happen Server…'));
    } else if (event['method'] == 'connection/ready' && _reopenOnConnect) {
      unawaited(navigate(uri, cancellation: _lifetime));
    }
  }

  @override
  Future<Object> evaluate(String script, {required CancellationToken cancellation}) =>
    throw UnsupportedError('Browser security prevents controlling an embedded website');

  @override
  Future<void> stop() async {
    if (!loading) return;
    _navigation?.cancel();
    _preview?.release();
    updateState(BrowserFailed(location, 'Preview loading stopped.'));
  }

  @override
  void close() {
    if (state is BrowserClosed) return;
    _lifetime.cancel();
    unawaited(_connection?.cancel());
    _preview?.release();
    updateState(const BrowserClosed(), notify: false);
    dispose();
  }
}
