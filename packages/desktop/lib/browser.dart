import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'appearance.dart';
import 'desktop_toast.dart';
import 'file_reference.dart';

/// Bare local addresses use HTTP; other bare hosts use HTTPS.
/// Text without a host opens as a web search, like OpenCode's address bar.
Uri browserAddress(String input) {
  final value = input.trim();
  if (value.isEmpty || value.toLowerCase() == 'about:blank') return Uri.parse('about:blank');
  if (value.startsWith('/')) return File(value).absolute.uri;
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

bool browserLocationAllowed(Uri uri) => !uri.toString().contains('\x00') &&
  uri.userInfo.isEmpty && (
    {'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty ||
    uri.scheme == 'file' && (uri.host.isEmpty || uri.host == 'localhost') && uri.path.startsWith('/') ||
    uri.toString() == 'about:blank'
  );

class ConversationBrowserScope extends InheritedWidget {
  const ConversationBrowserScope({super.key, required this.onOpen, required super.child});
  final ValueChanged<Uri> onOpen;

  static bool open(BuildContext context, Uri uri) {
    final scope = context.getInheritedWidgetOfExactType<ConversationBrowserScope>();
    if (scope == null) return false;
    scope.onOpen(uri);
    return true;
  }

  @override
  bool updateShouldNotify(ConversationBrowserScope oldWidget) => onOpen != oldWidget.onOpen;
}

Future<void> _openSystemBrowser(Uri uri, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final executable = Platform.isMacOS ? '/usr/bin/open'
    : Platform.isLinux ? 'xdg-open' : throw const FormatException('Unsupported platform');
  final process = await Process.start(executable, [uri.toString()]);
  final hook = CancellationHook(cancellation, process.kill);
  try {
    final results = await Future.wait<Object?>([
      process.exitCode, process.stdout.drain<Object?>(), process.stderr.drain<Object?>(),
    ]).asCancellable(cancellation);
    if (results.first != 0) throw const FileSystemException('Could not open browser');
  } finally { hook.dispose(); }
}

Future<void> openDesktopLink(BuildContext context, String href, {
    required String directory, required CancellationToken cancellation}) async {
  try {
    cancellation.throwIfCancelled();
    final file = conversationFileLocation(href, directory);
    if (file != null) {
      ConversationFileScope.open(context, file);
      return;
    }
    final uri = Uri.tryParse(href);
    if (uri == null || !{'http', 'https', 'mailto'}.contains(uri.scheme) ||
        uri.scheme != 'mailto' && !browserLocationAllowed(uri)) {
      throw const FormatException('Unsupported link');
    }
    if ({'http', 'https'}.contains(uri.scheme) && browserHostIsLocal(uri.host)) {
      if (!ConversationBrowserScope.open(context, uri)) throw StateError('Browser is unavailable');
      return;
    }
    await _openSystemBrowser(uri, cancellation);
  } on CancelledException {
    // Closing the source cancels opening its link.
  } catch (_) {
    if (context.mounted && !cancellation.isCancelled) {
      showDesktopToast(context, 'This link could not be opened.', type: DesktopToastType.error);
    }
  }
}

/// A retained browser tab, also used without the address bar for file previews.
/// [initialUrl] is restored when the tab mounts; subsequent navigation belongs
/// to its WebView. File reloads replace this widget using a new key.
class DesktopBrowser extends StatefulWidget {
  const DesktopBrowser({super.key, this.initialUrl = '', this.active = true,
    this.toolbar = true, this.navigationEnabled = true, this.directory, this.onPageChanged, this.onNewTab});
  final String initialUrl;
  final bool active, toolbar;
  /// File previews dispatch links to their desktop destination instead of
  /// navigating this WebView after its initial file load.
  final bool navigationEnabled;
  final String? directory;
  final void Function(String url, String title)? onPageChanged;
  final VoidCallback? onNewTab;

  @override
  State<DesktopBrowser> createState() => _DesktopBrowserState();
}

class _DesktopBrowserState extends State<DesktopBrowser> {
  final _lifetime = CancellationToken();
  final _address = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'Browser address');
  WebViewController? _controller;
  Future<WebViewController>? _opening;
  Uri? _location, _pendingFileLoad;
  String _title = '';
  String? _error;
  bool _back = false, _forward = false, _loading = false;
  int _progress = 0, _generation = 0, _navigation = 0;

  @override
  void initState() {
    super.initState();
    _addressFocus.addListener(_addressFocusChanged);
    if (widget.initialUrl.isNotEmpty) {
      try {
        _location = browserAddress(widget.initialUrl);
        _address.text = _location.toString() == 'about:blank' ? '' : _location.toString();
      } on FormatException catch (error) { _error = error.message; }
    }
    if (widget.active && _location != null) _start();
    if (widget.active && widget.toolbar && _location == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focusAddress();
      });
    }
  }

  @override
  void didUpdateWidget(DesktopBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && _controller == null && _opening == null && _location != null) {
      _start();
    }
  }

  void _start() {
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active && _controller == null && _opening == null && _location != null) {
        _run(() => _navigate(_location!));
      }
    });
  }

  void _addressFocusChanged() {
    if (!_addressFocus.hasFocus) _setAddress();
  }

  void _setAddress() {
    if (!_addressFocus.hasFocus) _address.text =
      _location?.toString() == 'about:blank' ? '' : _location?.toString() ?? '';
  }

  void _focusAddress() {
    _addressFocus.requestFocus();
    _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length);
  }

  void _run(Future<void> Function() action) {
    unawaited(() async {
      try {
        await action();
      } on CancelledException {
        // Closing the tab cancels pending platform calls.
      } catch (error) {
        if (mounted && !_lifetime.isCancelled) {
          if (_controller == null) _opening = null;
          setState(() { _loading = false; _error = error is FormatException
            ? error.message : 'This page could not be loaded. Check the address and try again.'; });
        }
      }
    }());
  }

  Future<WebViewController> _open() async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(widget.navigationEnabled
      ? JavaScriptMode.unrestricted : JavaScriptMode.disabled).asCancellable(_lifetime);
    if (controller.platform case final WebKitWebViewController webkit) {
      await webkit.setAllowsBackForwardNavigationGestures(widget.toolbar && widget.navigationEnabled)
        .asCancellable(_lifetime);
    }
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: _onNavigationRequest,
      onPageStarted: (url) {
        if (!mounted || _lifetime.isCancelled) return;
        _generation++;
        setState(() { _location = Uri.tryParse(url) ?? _location; _loading = true; _progress = 0; _error = null; });
        _setAddress();
      },
      onUrlChange: (change) {
        if (!mounted || _lifetime.isCancelled || change.url == null) return;
        setState(() => _location = Uri.tryParse(change.url!) ?? _location);
        _setAddress();
        _run(_updatePage);
      },
      onProgress: (progress) {
        if (mounted && !_lifetime.isCancelled) setState(() => _progress = progress);
      },
      onPageFinished: (_) {
        if (!mounted || _lifetime.isCancelled) return;
        setState(() { _loading = false; _progress = 100; });
        _run(_updatePage);
      },
      onWebResourceError: (error) {
        if (!mounted || _lifetime.isCancelled || error.isForMainFrame == false ||
            error.errorCode == -999) return; // WebKit reports superseded loads as cancelled.
        setState(() { _loading = false; _error = error.description; });
      },
    )).asCancellable(_lifetime);
    _lifetime.throwIfCancelled();
    setState(() => _controller = controller);
    return controller;
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    if (!mounted || _lifetime.isCancelled) return NavigationDecision.prevent;
    final uri = Uri.tryParse(request.url);
    if (request.isMainFrame && uri != null && uri == _pendingFileLoad) {
      _pendingFileLoad = null;
      return NavigationDecision.navigate;
    }
    // Subframes stay within their document. WebKit retargets new windows to the
    // main frame, where their destination follows the same rules as any link.
    if (widget.navigationEnabled && !request.isMainFrame) {
      return uri != null && browserLocationAllowed(uri)
        ? NavigationDecision.navigate : NavigationDecision.prevent;
    }
    if (widget.navigationEnabled && uri != null && browserLocationAllowed(uri) &&
        (uri.toString() == 'about:blank' ||
          widget.toolbar && {'http', 'https'}.contains(uri.scheme) && browserHostIsLocal(uri.host))) {
      return NavigationDecision.navigate;
    }
    if (!widget.navigationEnabled && (uri == null ||
        !{'file', 'http', 'https', 'mailto'}.contains(uri.scheme))) {
      return NavigationDecision.prevent;
    }
    unawaited(openDesktopLink(context, request.url,
      directory: widget.directory ?? '', cancellation: _lifetime));
    return NavigationDecision.prevent;
  }

  Future<void> _navigate(Uri uri) async {
    if (!browserLocationAllowed(uri)) throw const FormatException('Enter a web address or a local file.');
    if (widget.toolbar && uri.toString() != 'about:blank' &&
        !(uri.scheme != 'file' && browserHostIsLocal(uri.host))) {
      await openDesktopLink(context, uri.toString(),
        directory: widget.directory ?? '', cancellation: _lifetime);
      if (_controller == null && mounted) setState(() { _location = null; _setAddress(); });
      return;
    }
    final navigation = ++_navigation;
    setState(() { _location = uri; _title = ''; _error = null; _loading = true; _progress = 0; });
    _setAddress();
    widget.onPageChanged?.call(uri.toString(), '');
    final controller = _controller ?? await (_opening ??= _open());
    _lifetime.throwIfCancelled();
    if (navigation != _navigation) return;
    if (uri.scheme == 'file') {
      final path = uri.replace(host: '', fragment: '', query: '').toFilePath();
      _pendingFileLoad = File(path).absolute.uri;
      final directory = widget.directory;
      final root = Directory(directory ?? File(path).parent.path).absolute.uri.normalizePath();
      final readAccess = File(path).absolute.uri.normalizePath().path.startsWith(root.path)
        ? root.toFilePath() : File(path).parent.path;
      if (controller.platform case final WebKitWebViewController webkit) {
        await webkit.loadFileWithParams(WebKitLoadFileParams(
          absoluteFilePath: path, readAccessPath: readAccess)).asCancellable(_lifetime);
      } else {
        await controller.loadFile(path).asCancellable(_lifetime);
      }
    } else {
      await controller.loadRequest(uri).asCancellable(_lifetime);
    }
  }

  Future<void> _updatePage() async {
    final controller = _controller;
    if (controller == null) return;
    final generation = ++_generation;
    final values = await Future.wait<Object?>([
      controller.currentUrl(), controller.getTitle(), controller.canGoBack(), controller.canGoForward(),
    ]).asCancellable(_lifetime);
    if (!mounted || generation != _generation) return;
    setState(() {
      if (values[0] case final String url when url.isNotEmpty) _location = Uri.tryParse(url) ?? _location;
      _title = values[1] as String? ?? '';
      _back = values[2] as bool; _forward = values[3] as bool;
    });
    _setAddress();
    widget.onPageChanged?.call(_location?.toString() ?? '', _title);
  }

  void _submit(String value) {
    try {
      final uri = browserAddress(value);
      _addressFocus.unfocus();
      _run(() => _navigate(uri));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _reload() async {
    if (_controller == null || _error != null) {
      if (_location != null) await _navigate(_location!);
      return;
    }
    setState(() { _error = null; _loading = true; _progress = 0; });
    await _controller!.reload().asCancellable(_lifetime);
  }

  Future<void> _stop() async {
    await _controller?.runJavaScript('window.stop();').asCancellable(_lifetime);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _external() async {
    if (_location == null) return;
    await _openSystemBrowser(_location!, _lifetime);
  }

  @override
  void dispose() {
    _lifetime.cancel();
    final controller = _controller;
    if (controller != null) unawaited(controller.runJavaScript('window.stop();').catchError((Object _) {}));
    _addressFocus.dispose();
    _address.dispose();
    super.dispose();
  }

  Widget _button(String label, IconData icon, VoidCallback? action) => SizedBox.square(
    dimension: 28, child: IconButton(tooltip: label, onPressed: action,
      padding: EdgeInsets.zero, icon: Icon(icon, size: 16),
      style: IconButton.styleFrom(minimumSize: const Size.square(28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: desktopSecondary)));

  Widget _message(IconData icon, String title, String detail, {bool retry = false}) => Center(
    child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 28, color: desktopTertiary), const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: desktopSecondary)),
      const SizedBox(height: 8),
      Text(detail, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: desktopTertiary)),
      if (retry) ...[const SizedBox(height: 12), TextButton(onPressed: () => _run(_reload), child: const Text('Retry'))],
    ])));

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return _message(Icons.language_rounded, 'Browser is available on macOS.', 'Open this page in your system browser.');
    }
    final blank = _location == null || _location.toString() == 'about:blank';
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return CallbackShortcuts(bindings: {
      if (widget.toolbar && widget.navigationEnabled) ...{
        SingleActivator(LogicalKeyboardKey.keyL, meta: mac, control: !mac): _focusAddress,
        SingleActivator(LogicalKeyboardKey.keyR, meta: mac, control: !mac): () => _run(_reload),
        SingleActivator(LogicalKeyboardKey.bracketLeft, meta: mac, control: !mac):
          () { if (_back) _run(_controller!.goBack); },
        SingleActivator(LogicalKeyboardKey.bracketRight, meta: mac, control: !mac):
          () { if (_forward) _run(_controller!.goForward); },
        if (widget.onNewTab != null)
          SingleActivator(LogicalKeyboardKey.keyT, meta: mac, control: !mac): widget.onNewTab!,
      },
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (_addressFocus.hasFocus) { _addressFocus.unfocus(); _setAddress(); }
        else if (_loading) { _run(_stop); }
      },
    }, child: Column(children: [
      if (widget.toolbar) Container(height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: desktopBorder, width: .5))),
        child: Row(children: [
          _button('Back', Icons.arrow_back_rounded, _back ? () => _run(_controller!.goBack) : null),
          _button('Forward', Icons.arrow_forward_rounded, _forward ? () => _run(_controller!.goForward) : null),
          _button(_loading ? 'Stop loading' : 'Reload page', _loading ? Icons.close_rounded : Icons.refresh_rounded,
            blank && !_loading ? null : () => _run(_loading ? _stop : _reload)),
          const SizedBox(width: 6),
          Expanded(child: TextField(key: const ValueKey('browser-address'),
            controller: _address, focusNode: _addressFocus, onSubmitted: _submit,
            style: const TextStyle(fontSize: 12, color: desktopForeground),
            decoration: InputDecoration(hintText: 'Search or enter a URL', isDense: true,
              filled: true, fillColor: desktopMuted, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none)),
            onTap: () {
              _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length);
            })),
          const SizedBox(width: 6),
          _button('Copy link', Icons.link_rounded, blank ? null : () => _run(() =>
            Clipboard.setData(ClipboardData(text: _location.toString())).asCancellable(_lifetime))),
          _button('Open in system browser', Icons.open_in_new_rounded, blank ? null : () => _run(_external)),
        ])),
      if (_loading) LinearProgressIndicator(minHeight: 2,
        value: _progress > 0 ? _progress / 100 : null, color: desktopSecondary, backgroundColor: desktopMuted),
      Expanded(child: _error != null
        ? _message(Icons.error_outline_rounded, 'This page could not be loaded.', _error!, retry: _location != null)
        : blank ? _message(Icons.language_rounded, 'Open a page', 'Preview your app, read docs, or browse the web.')
        : _controller == null ? const Center(child: SizedBox.square(dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2)))
        : WebViewWidget(key: const ValueKey('browser-webview'), controller: _controller!)),
    ]));
  }
}
