import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

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
  InternetAddress.tryParse(host)?.isLoopback == true;

bool browserLocationAllowed(Uri uri) => !uri.toString().contains('\x00') && uri.userInfo.isEmpty && (
  {'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty ||
  uri.scheme == 'file' && (uri.host.isEmpty || uri.host == 'localhost') && uri.path.startsWith('/') ||
  uri.toString() == 'about:blank'
);

sealed class BrowserPageState {
  const BrowserPageState(this.location);
  final Uri? location;
}
final class BrowserDormant extends BrowserPageState { const BrowserDormant(super.location); }
final class BrowserLoading extends BrowserPageState {
  const BrowserLoading(super.location, [this.progress = 0]);
  final int progress;
}
final class BrowserReady extends BrowserPageState { const BrowserReady(super.location); }
final class BrowserFailed extends BrowserPageState {
  const BrowserFailed(super.location, this.error);
  final String error;
}
final class BrowserClosed extends BrowserPageState { const BrowserClosed() : super(null); }

BrowserPageState _transition(BrowserPageState current, BrowserPageState next) => switch ((current, next)) {
  (BrowserDormant(), BrowserLoading() || BrowserFailed()) => next,
  (BrowserLoading() || BrowserReady() || BrowserFailed(), BrowserLoading() || BrowserReady() || BrowserFailed()) => next,
  (_, BrowserClosed()) when current is! BrowserClosed => next,
  _ => throw StateError('Invalid browser page transition'),
};

/// Owns a native page independently of the currently displayed workspace.
/// WebKit owns networking; this owner dispatches platform requests only.
class BrowserPage extends ChangeNotifier {
  BrowserPage({String initialUrl = '', this.navigationEnabled = true, this.toolbar = true, this.directory}) {
    try { _state = BrowserDormant(initialUrl.isEmpty ? null : browserAddress(initialUrl)); }
    on FormatException catch (error) { _state = BrowserFailed(null, error.message); }
  }
  final bool navigationEnabled, toolbar;
  final String? directory;
  final _lifetime = CancellationToken();
  late BrowserPageState _state;
  BrowserPageState get state => _state;
  Uri? get location => _state.location;
  String get title => _title;
  String? get error => switch (_state) { BrowserFailed(:final error) => error, _ => null };
  bool get loading => _state is BrowserLoading;
  int get progress => switch (_state) { BrowserLoading(:final progress) => progress, _ => 100 };
  bool get blank => location == null || location.toString() == 'about:blank';
  bool get canGoBack => _back;
  bool get canGoForward => _forward;
  WebViewController? get controller => _controller;
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

  void _set(BrowserPageState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> start({required CancellationToken cancellation}) async {
    if (_state is BrowserDormant && !blank) await navigate(location!, cancellation: cancellation);
  }

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
        if (navigationEnabled && uri != null && browserLocationAllowed(uri)) return NavigationDecision.navigate;
        if (request.isMainFrame && uri != null) onExternalNavigation?.call(uri);
        return NavigationDecision.prevent;
      },
      onPageStarted: (url) {
        if (_lifetime.isCancelled) return;
        if (_loaded == null || _loaded!.isCompleted) _loaded = Completer<void>();
        _generation++;
        _annotationDocument = newId();
        _set(BrowserLoading(Uri.tryParse(url) ?? location));
      },
      onUrlChange: (change) {
        if (_lifetime.isCancelled || change.url == null) return;
        final uri = Uri.tryParse(change.url!) ?? location;
        _set(loading ? BrowserLoading(uri, progress) : BrowserReady(uri));
        unawaited(_updatePage());
      },
      onProgress: (value) {
        if (!_lifetime.isCancelled && loading) _set(BrowserLoading(location, value));
      },
      onPageFinished: (url) {
        if (Uri.tryParse(url) == location) unawaited(_finish());
      },
      onWebResourceError: (error) {
        if (_lifetime.isCancelled || error.isForMainFrame == false || error.errorCode == -999) return;
        _set(BrowserFailed(location, error.description));
        _completeLoad();
      },
    )).asCancellable(_lifetime);
    _lifetime.throwIfCancelled();
    _controller = controller;
    return controller;
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
    if (_lifetime.isCancelled || generation != _generation || _state is BrowserFailed) return;
    _set(BrowserReady(location));
    _completeLoad();
  }

  void _completeLoad() {
    if (_loaded?.isCompleted == false) _loaded!.complete();
  }

  Future<void> navigate(Uri uri, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    _lifetime.throwIfCancelled();
    if (!browserLocationAllowed(uri)) throw const FormatException('Enter a web address or a local file.');
    _operation?.cancel();
    _completeLoad();
    final operation = _operation = CancellationToken();
    final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
    final token = cancellation.merge(operation).merge(_lifetime).merge(deadline);
    final navigation = ++_navigation;
    final loaded = _loaded = Completer<void>();
    _title = '';
    _set(BrowserLoading(uri));
    final hook = CancellationHook(token, () {
      if (navigation != _navigation || _lifetime.isCancelled) return;
      unawaited(_controller?.runJavaScript('window.stop();').catchError((Object _) {}));
      if (loading) _set(BrowserReady(location));
      _completeLoad();
    });
    try {
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
      } else { await controller.loadRequest(uri).asCancellable(token); }
      await loaded.future.asCancellable(token);
      token.throwIfCancelled();
      if (error case final message?) throw StateError(message);
    } on CancelledException {
      rethrow;
    } catch (error) {
      if (!token.isCancelled && navigation == _navigation) {
        _opening = null;
        _set(BrowserFailed(uri, error.toString()));
      }
      rethrow;
    } finally { hook.dispose(); deadline.cancel(); }
  }

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

  Future<void> stop() async {
    _operation?.cancel();
    if (loading) _set(BrowserReady(location));
    _completeLoad();
    await _controller?.runJavaScript('window.stop();').asCancellable(_lifetime);
  }

  void close() {
    if (_state is BrowserClosed) return;
    _lifetime.cancel();
    _operation?.cancel();
    _completeLoad();
    unawaited(_controller?.runJavaScript('window.stop();').catchError((Object _) {}));
    _controller = null;
    _set(const BrowserClosed());
    dispose();
  }
}
