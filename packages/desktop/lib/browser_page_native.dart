import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';
import 'package:server/dev_servers.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'browser_page.dart' show BrowserPage, BrowserDormant, BrowserLoading, BrowserReady, BrowserFailed, BrowserClosed;
import 'browser_preview.dart';
import 'connection.dart' show AgentClient;

Uri browserAddress(String input) {
  final value = input.trim();
  if (value.isEmpty || value.toLowerCase() == 'about:blank') return Uri.parse('about:blank');
  if (value.startsWith('/')) return Uri.file(value);
  if (RegExp(r'^[a-z][a-z\d+.-]*://', caseSensitive: false).hasMatch(value) ||
      RegExp(r'^(about|data|javascript|mailto):', caseSensitive: false).hasMatch(value)) {
    final uri = Uri.tryParse(value);
    if (uri == null || !browserLocationAllowed(uri)) throw const FormatException('Enter a web address or a local file.');
    return uri;
  }
  if (!value.contains(RegExp(r'\s'))) {
    final uri = Uri.tryParse('https://$value');
    if (uri != null && (uri.host.contains('.') || uri.host == 'localhost' ||
        InternetAddress.tryParse(uri.host) != null || uri.hasPort)) {
      final address = browserHostIsLocal(uri.host) ? uri.replace(scheme: 'http') : uri;
      if (browserLocationAllowed(address)) return address;
    }
  }
  return Uri.https('www.google.com', '/search', {'q': value});
}

bool browserHostIsLocal(String host) => host == 'localhost' || host.endsWith('.localhost') ||
  host == '0.0.0.0' || InternetAddress.tryParse(host)?.isLoopback == true;

bool browserLocationAllowed(Uri uri) => !uri.toString().contains('\x00') && uri.userInfo.isEmpty && (
  {'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty ||
  uri.scheme == 'file' && (uri.host.isEmpty || uri.host == 'localhost') && uri.path.startsWith('/') ||
  uri.toString() == 'about:blank'
);

/// Owns a native page independently of the currently displayed workspace.
/// WebKit owns networking; this owner dispatches platform requests only.
class PlatformBrowserPage extends BrowserPage {
  PlatformBrowserPage({String initialUrl = '', this.navigationEnabled = true, this.toolbar = true, this.directory,
      AgentClient? client}) : _preview = client == null || client.sharedFilesystem ? null : BrowserPreview(client),
      super.platform(initialUrl, browserAddress) {
    _connection = _preview?.client.events.stream.listen(_connectionChanged);
  }
  final bool navigationEnabled, toolbar;
  final String? directory;
  final BrowserPreview? _preview;
  StreamSubscription<Json>? _connection;
  bool _reopenOnConnect = false;
  final _lifetime = CancellationToken();
  @override
  Uri? get loadAddress => switch (location) { final uri? => _preview?.loadAddress(uri) ?? uri, null => null };
  Uri displayAddress(Uri uri) => _preview?.displayAddress(uri) ?? uri;
  @override
  Future<List<Json>> Function({required CancellationToken cancellation}) get discoverPorts =>
    _preview?.client.discoverRemoteDevServers ?? discoverDevServers;
  @override
  String get title => _title;
  bool get canGoBack => _back;
  bool get canGoForward => _forward;
  WebViewController? get controller => _controller;
  @override
  int get generation => _generation;
  String get annotationDocument => _annotationDocument;
  ValueChanged<Uri>? onExternalNavigation;
  ValueChanged<JavaScriptMessage>? onAnnotationMessage;
  WebViewController? _controller;
  Future<WebViewController>? _opening;
  Future<void>? _annotationSetup;
  String _title = '';
  bool _back = false, _forward = false;
  int _generation = 0, _navigation = 0;
  String _annotationDocument = newId();
  Uri? _pendingFileLoad;
  CancellationToken? _operation;
  Completer<void>? _loaded;

  Future<WebViewController> _open() async {
    if (defaultTargetPlatform != TargetPlatform.macOS) throw StateError('Browser is available on macOS.');
    final controller = WebViewController();
    await controller.setJavaScriptMode(navigationEnabled ? JavaScriptMode.unrestricted : JavaScriptMode.disabled)
      .asCancellable(_lifetime);
    if (controller.platform case final WebKitWebViewController webkit) {
      await webkit.setAllowsBackForwardNavigationGestures(toolbar && navigationEnabled).asCancellable(_lifetime);
    }
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (request) {
        if (_lifetime.isCancelled) return NavigationDecision.prevent;
        final uri = Uri.tryParse(request.url);
        if (request.isMainFrame && uri == _pendingFileLoad) {
          _pendingFileLoad = null;
          return NavigationDecision.navigate;
        }
        if (request.isMainFrame && navigationEnabled && uri != null && browserLocationAllowed(uri) && _isRemotePreview(uri)) {
          // Some dev servers issue absolute loopback links or redirects.
          final target = _preview!.loadAddress(uri);
          unawaited(Future<void>(() async {
            if (_lifetime.isCancelled) return;
            if (target == uri) { await navigate(uri, cancellation: _lifetime); }
            else { await controller.loadRequest(target).asCancellable(_lifetime); }
          }).catchError((Object _) {}));
          return NavigationDecision.prevent;
        }
        if (navigationEnabled && uri != null && browserLocationAllowed(uri)) return NavigationDecision.navigate;
        if (request.isMainFrame && uri != null) onExternalNavigation?.call(uri);
        return NavigationDecision.prevent;
      },
      onPageStarted: (url) {
        if (_lifetime.isCancelled) return;
        if (_loaded == null || _loaded!.isCompleted) _loaded = Completer<void>();
        _generation++;
        _annotationDocument = newId();
        updateState(BrowserLoading(_displayLocation(url) ?? location));
      },
      onUrlChange: (change) {
        if (_lifetime.isCancelled || change.url == null) return;
        final uri = _displayLocation(change.url!) ?? location;
        updateState(loading ? BrowserLoading(uri, progress) : BrowserReady(uri));
        unawaited(_updatePage());
      },
      onProgress: (value) {
        if (!_lifetime.isCancelled && loading) updateState(BrowserLoading(location, value));
      },
      onPageFinished: (url) {
        if (_displayLocation(url) == location) unawaited(_finish());
      },
      onWebResourceError: (error) {
        if (_lifetime.isCancelled || error.isForMainFrame == false || error.errorCode == -999) return;
        updateState(BrowserFailed(location, error.description));
        _completeLoad();
      },
    )).asCancellable(_lifetime);
    _lifetime.throwIfCancelled();
    _controller = controller;
    return controller;
  }

  Uri? _displayLocation(String url) {
    final uri = Uri.tryParse(url);
    return uri == null ? null : displayAddress(uri);
  }

  bool _isRemotePreview(Uri uri) => _preview != null && (uri.scheme == 'http' || uri.scheme == 'https') &&
    browserHostIsLocal(uri.host);

  void _connectionChanged(Json event) {
    final uri = location;
    if (_lifetime.isCancelled || state is BrowserDormant || uri == null || !_isRemotePreview(uri)) return;
    if (event['method'] == 'connection/closed' && (_preview?.isOpen == true || loading || _reopenOnConnect)) {
      _operation?.cancel();
      _preview?.release();
      _reopenOnConnect = true;
      updateState(BrowserFailed(uri, 'Reconnecting to Happen Server…'));
    } else if (event['method'] == 'connection/ready' && _reopenOnConnect) {
      unawaited(navigate(uri, cancellation: _lifetime).catchError((Object _) {}));
    }
  }

  Future<void> _updatePage() async {
    final controller = _controller, generation = _generation;
    if (controller == null || _lifetime.isCancelled) return;
    try {
      final values = await Future.wait<Object?>([
        controller.getTitle(), controller.canGoBack(), controller.canGoForward(),
      ]).asCancellable(_lifetime);
      if (generation != _generation || _lifetime.isCancelled) return;
      _title = values[0] as String? ?? '';
      _back = values[1] as bool;
      _forward = values[2] as bool;
      notifyListeners();
    } on CancelledException { /* Closing owns native requests. */ }
    catch (_) { /* Metadata may disappear during a navigation. */ }
  }

  Future<void> _finish() async {
    final generation = _generation;
    await _updatePage();
    if (_lifetime.isCancelled || generation != _generation || state is BrowserFailed) return;
    updateState(BrowserReady(location));
    _completeLoad();
  }

  void _completeLoad() {
    if (_loaded?.isCompleted == false) _loaded!.complete();
  }

  @override
  Future<void> navigate(Uri uri, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    _lifetime.throwIfCancelled();
    if (!browserLocationAllowed(uri)) throw const FormatException('Enter a web address or a local file.');
    _operation?.cancel();
    _reopenOnConnect = false;
    _completeLoad();
    final operation = _operation = CancellationToken();
    final remote = _isRemotePreview(uri);
    final deadline = TimeoutCancellationToken(Duration(seconds: remote ? 60 : 30));
    final token = cancellation.merge(operation).merge(_lifetime).merge(deadline);
    final navigation = ++_navigation;
    final loaded = _loaded = Completer<void>();
    _title = '';
    updateState(BrowserLoading(uri));
    final hook = CancellationHook(token, () {
      if (navigation != _navigation || _lifetime.isCancelled) return;
      unawaited(_controller?.runJavaScript('window.stop();').catchError((Object _) {}));
      if (loading) updateState(BrowserReady(location));
      _completeLoad();
    });
    try {
      var target = uri;
      if (remote) {
        _reopenOnConnect = !_preview!.client.isConnected;
        target = await _preview.open(uri, token);
      } else { _preview?.release(); }
      final controller = _controller ?? await (_opening ??= _open()).asCancellable(token);
      token.throwIfCancelled();
      if (uri.scheme == 'file') {
        final path = uri.replace(host: '', query: '', fragment: '').toFilePath();
        _pendingFileLoad = Uri.file(path);
        final root = Uri.directory(directory ?? File(path).parent.path).normalizePath();
        final readAccess = Uri.file(path).normalizePath().path.startsWith(root.path) ? root.toFilePath() : File(path).parent.path;
        if (controller.platform case final WebKitWebViewController webkit) {
          await webkit.loadFileWithParams(WebKitLoadFileParams(absoluteFilePath: path, readAccessPath: readAccess)).asCancellable(token);
        } else { await controller.loadFile(path).asCancellable(token); }
      } else { await controller.loadRequest(target).asCancellable(token); }
      await loaded.future.asCancellable(token);
      token.throwIfCancelled();
      if (error case final message?) throw StateError(message);
    } on CancelledException {
      rethrow;
    } catch (error) {
      if (!token.isCancelled && navigation == _navigation) {
        _opening = null;
        updateState(BrowserFailed(uri, error.toString()));
      }
      rethrow;
    } finally { hook.dispose(); deadline.cancel(); }
  }

  @override
  Future<Object> evaluate(String script, {required CancellationToken cancellation}) async {
    await start(cancellation: cancellation);
    if (loading && _loaded != null) await _loaded!.future.asCancellable(cancellation.merge(_lifetime));
    cancellation.throwIfCancelled();
    if (error case final message?) throw StateError(message);
    final controller = _controller;
    if (controller == null) throw StateError('Open a page in this tab first.');
    return controller.runJavaScriptReturningResult(script).asCancellable(cancellation.merge(_lifetime));
  }

  Future<void> installAnnotationChannel({required CancellationToken cancellation}) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await (_annotationSetup ??= controller.addJavaScriptChannel('HappenAnnotation',
        onMessageReceived: (message) => onAnnotationMessage?.call(message))).asCancellable(cancellation.merge(_lifetime));
    } catch (_) {
      if (!cancellation.isCancelled && !_lifetime.isCancelled) _annotationSetup = null;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    _operation?.cancel();
    if (loading) updateState(BrowserReady(location));
    _completeLoad();
    await _controller?.runJavaScript('window.stop();').asCancellable(_lifetime);
  }

  @override
  void close() {
    if (state is BrowserClosed) return;
    _lifetime.cancel();
    unawaited(_connection?.cancel());
    _preview?.release();
    _operation?.cancel();
    _completeLoad();
    unawaited(_controller?.runJavaScript('window.stop();').catchError((Object _) {}));
    _controller = null;
    updateState(const BrowserClosed());
    dispose();
  }
}
