import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:protocol/protocol.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'appearance.dart';
import 'browser.dart' show ConversationBrowserScope, DesktopBrowser;
import 'desktop_toast.dart';
import 'file_reference.dart';
import 'browser_annotation_script.dart';
import 'conversation_annotations.dart';
import 'response_annotation.dart';
import 'browser_page.dart';
import 'browser_page_native.dart' show PlatformBrowserPage;
import 'browser_ports.dart';

Future<void> _openSystemBrowser(Uri uri, CancellationToken cancellation) =>
  runIsolateEffect(_openSystemBrowserEffect, {'uri': uri.toString()}, cancellation: cancellation);

Future<void> _openSystemBrowserEffect(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  cancellation.throwIfCancelled();
  final executable = Platform.isMacOS ? '/usr/bin/open'
    : Platform.isLinux ? 'xdg-open' : throw const FormatException('Unsupported platform');
  final process = await Process.start(executable, [requiredString(params, 'uri')]);
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

State<DesktopBrowser> createDesktopBrowserState() => _DesktopBrowserState();

class _DesktopBrowserState extends State<DesktopBrowser> {
  final _lifetime = CancellationToken();
  final _address = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'Browser address');
  late PlatformBrowserPage _page;
  WebViewController? get _controller => _page.controller;
  Uri? get _location => _page.location;
  String? _error;
  bool get _back => _page.canGoBack;
  bool get _forward => _page.canGoForward;
  bool get _loading => _page.loading;
  int get _progress => _page.progress;
  int _generation = 0;
  bool _wasLoading = false;
  late final _pageKey = GlobalKey();
  late bool _commenting = false, _annotationReady = false;
  String? _annotationDocument;
  CancellationToken? _annotationOperation;
  ConversationAnnotationScope? _annotations;
  StreamSubscription<String>? _annotationSends;
  int _annotationModeRevision = 0;
  late final _annotationSelections = <int>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = ConversationAnnotationScope.maybeOf(context);
    final previous = _annotations;
    _annotations = scope;
    if (scope?.changes != previous?.changes) {
      previous?.changes.removeListener(_reconcileAnnotations);
      scope?.changes.addListener(_reconcileAnnotations);
    }
    if (scope?.browserAnnotationSends != previous?.browserAnnotationSends) {
      unawaited(_annotationSends?.cancel());
      _annotationSends = scope?.browserAnnotationSends?.listen((draft) {
        if (mounted && draft == _annotations?.draftKey) _setAnnotationMode(false);
      });
    }
    if (scope?.enabled != true || scope?.draftKey != previous?.draftKey) _setAnnotationMode(false);
    if (scope?.enabled != previous?.enabled || scope?.draftKey != previous?.draftKey || scope?.changes != previous?.changes) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_annotationReady) { _reconcileAnnotations(); }
        else { _annotationEffect(_installAnnotations); }
      });
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    if (_controller != null && !_loading) _annotationEffect(_installAnnotations);
  }

  void _resetAnnotations() {
    _annotationOperation?.cancel();
    _annotationOperation = CancellationToken();
    _annotationDocument = _page.annotationDocument;
    _annotationSelections.clear();
    _annotationReady = false;
  }

  void _annotationEffect(Future<void> Function() effect) {
    unawaited(() async {
      try { await effect(); }
      on CancelledException { /* Navigation or closing the tab owns cancellation. */ }
      catch (_) {
        if (mounted && !_lifetime.isCancelled && widget.active) {
          showDesktopToast(context, 'This page could not be annotated. Reload it and try again.', type: DesktopToastType.error);
        }
      }
    }());
  }

  Future<void> _installAnnotations() async {
    final controller = _controller;
    if (!mounted || controller == null || !widget.toolbar || !widget.navigationEnabled || _annotations?.enabled != true || _loading) return;
    await _page.installAnnotationChannel(cancellation: _lifetime);
    if (_annotationDocument == null) _resetAnnotations();
    final document = _annotationDocument;
    final cancellation = _annotationOperation!.merge(_lifetime);
    await controller.runJavaScript(browserAnnotationScript.replaceAll('__HAPPEN_DOCUMENT__', document!)).asCancellable(cancellation);
    if (!mounted || document != _annotationDocument) return;
    _annotationReady = true;
    await controller.runJavaScript('__happenBrowserAnnotations.setMode(${widget.active && _commenting});').asCancellable(cancellation);
    _reconcileAnnotations();
    if (mounted) setState(() {});
  }

  void _reconcileAnnotations() {
    if (!_annotationReady || _controller == null || _annotations == null) return;
    final ids = _annotations!.readAnnotations().map((annotation) => annotation.id).toList();
    final cancellation = _annotationOperation!.merge(_lifetime);
    _annotationEffect(() => _controller!.runJavaScript('__happenBrowserAnnotations.reconcile(${jsonEncode(ids)});')
      .asCancellable(cancellation));
  }

  void _annotationMessage(JavaScriptMessage message) {
    if (!mounted || !widget.active || !_annotationReady || message.message.length > 96 * 1024) return;
    try {
      final value = jsonObject(jsonDecode(message.message));
      if (value['document'] != _annotationDocument) return;
      if (value['type'] == 'escape') {
        _setAnnotationMode(false, updatePage: false);
        return;
      }
      if (_loading || _annotations?.enabled != true || value['type'] != 'selection' ||
          value['serial'] is! int || value['target'] is! Map) return;
      final serial = value['serial'] as int;
      if (serial < 1 || !_annotationSelections.add(serial)) return;
      final target = jsonObject(value['target']);
      final uri = _page.localAddress(Uri.parse(requiredString(target, 'pageUrl')));
      if (uri != _location) return;
      final browser = BrowserAnnotation({...target, 'pageUrl': uri.toString()});
      final requiresMode = browser.target['kind'] != 'text';
      if (requiresMode && !_commenting) return;
      final annotation = ResponseAnnotation(id: newId(), text: browser.label, browser: browser);
      final scope = _annotations!, document = _annotationDocument;
      final revision = _annotationModeRevision;
      final cancellation = _annotationOperation!.merge(_lifetime);
      _annotationEffect(() async {
        final number = scope.readAnnotations().length + 1;
        await _controller!.runJavaScript('__happenBrowserAnnotations.commit(${jsonEncode(annotation.id)},$number,$serial);')
          .asCancellable(cancellation);
        if (!mounted || document != _annotationDocument) return;
        if (!widget.active || scope.draftKey != _annotations?.draftKey || _annotations?.enabled != true ||
            requiresMode && revision != _annotationModeRevision) {
          _reconcileAnnotations();
          return;
        }
        final rect = browser.target['rect'] as Map<String, num>?;
        final box = _pageKey.currentContext?.findRenderObject();
        final anchor = box is RenderBox && box.hasSize ? box.localToGlobal(Offset(
          (rect?['x']?.toDouble() ?? 16).clamp(0, box.size.width),
          (rect?['y']?.toDouble() ?? 16).clamp(0, box.size.height))) : const Offset(24, 80);
        scope.onAdd(annotation, anchor);
      });
    } catch (_) { /* Page messages are optional, untrusted evidence. */ }
  }

  void _setAnnotationMode(bool enabled, {bool updatePage = true}) {
    if (_commenting == enabled || enabled && !_annotationReady) return;
    setState(() { _commenting = enabled; _annotationModeRevision++; });
    if (enabled) { FocusManager.instance.addEarlyKeyEventHandler(_annotationEscape); }
    else { FocusManager.instance.removeEarlyKeyEventHandler(_annotationEscape); }
    final controller = _controller;
    if (!updatePage || !_annotationReady || controller == null) return;
    final cancellation = _annotationOperation!.merge(_lifetime);
    _annotationEffect(() => controller.runJavaScript('__happenBrowserAnnotations.setMode($enabled);').asCancellable(cancellation));
  }

  KeyEventResult _annotationEscape(KeyEvent event) {
    if (!_commenting || !widget.active || ModalRoute.of(context)?.isCurrent == false ||
        !const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false).accepts(event, HardwareKeyboard.instance)) {
      return KeyEventResult.ignored;
    }
    _setAnnotationMode(false);
    if (_addressFocus.hasFocus) { _addressFocus.unfocus(); _setAddress(); }
    // Let the focused annotation editor save and close its comment as usual.
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused?.findAncestorWidgetOfExactType<ResponseAnnotationEditor>() != null
      ? KeyEventResult.ignored : KeyEventResult.handled;
  }

  @override
  void initState() {
    super.initState();
    _attachPage();
    _addressFocus.addListener(_addressFocusChanged);
    _setAddress();
    if (widget.active && _location != null) _start();
    if (widget.active && widget.toolbar && _location == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focusAddress();
      });
    }
  }

  void _attachPage() {
    _page = (widget.page as PlatformBrowserPage?) ?? PlatformBrowserPage(initialUrl: widget.initialUrl,
      toolbar: widget.toolbar, navigationEnabled: widget.navigationEnabled, directory: widget.directory);
    _page.addListener(_pageChanged);
    _page.onExternalNavigation = _externalNavigation;
    _page.onAnnotationMessage = _annotationMessage;
  }

  @override
  void didUpdateWidget(DesktopBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) {
      _page.removeListener(_pageChanged);
      _page.onExternalNavigation = null;
      _page.onAnnotationMessage = null;
      if (oldWidget.page == null) _page.close();
      _attachPage();
      _resetAnnotations();
      _setAddress();
    }
    if (widget.active && _page.state is BrowserDormant && _location != null) {
      _start();
    }
    if (!widget.active && oldWidget.active) _setAnnotationMode(false);
  }

  void _start() {
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) {
        _run(() => _page.start(cancellation: _lifetime));
      }
    });
  }

  void _externalNavigation(Uri uri) => unawaited(openDesktopLink(context, uri.toString(),
    directory: widget.directory ?? '', cancellation: _lifetime));

  void _pageChanged() {
    if (!mounted) return;
    if (_generation != _page.generation) {
      _generation = _page.generation;
      _resetAnnotations();
    }
    final finished = _wasLoading && !_loading;
    _wasLoading = _loading;
    _error = _page.error;
    _setAddress();
    widget.onPageChanged?.call(_location?.toString() ?? '', _page.title);
    setState(() {});
    if (finished && _page.error == null) _annotationEffect(_installAnnotations);
  }

  void _addressFocusChanged() {
    if (!_addressFocus.hasFocus) _setAddress();
  }

  void _setAddress() {
    if (!_addressFocus.hasFocus) _address.text = _page.addressBarLocation?.toString() ?? '';
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
          setState(() { _error = error is FormatException
            ? error.message : 'This page could not be loaded. Check the address and try again.'; });
        }
      }
    }());
  }

  Future<void> _navigate(Uri uri) => _page.navigate(uri, cancellation: _lifetime);

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
    if (_location != null) await _navigate(_location!);
  }

  Future<void> _stop() => _page.stop();

  Future<void> _external() async {
    if (_page.loadAddress case final uri?) await _openSystemBrowser(uri, _lifetime);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_annotationEscape);
    _annotations?.changes.removeListener(_reconcileAnnotations);
    unawaited(_annotationSends?.cancel());
    _annotationOperation?.cancel();
    if (_commenting && _annotationReady && _controller != null) {
      unawaited(_controller!.runJavaScript('__happenBrowserAnnotations.setMode(false);')
        .asCancellable(_lifetime).catchError((Object _) {}));
    }
    _lifetime.cancel();
    _page.removeListener(_pageChanged);
    _page.onExternalNavigation = null;
    _page.onAnnotationMessage = null;
    if (widget.page == null) _page.close();
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
    final blank = _page.blank;
    final error = _error ?? _page.error;
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
          if (widget.navigationEnabled && _annotations?.enabled == true) _button(
            _commenting ? 'Stop annotating' : 'Annotate page', Icons.add_comment_outlined,
            _annotationReady && !blank && !_loading ? () => _setAnnotationMode(!_commenting) : null),
          _button('Copy link', Icons.link_rounded, switch (_page.addressBarLocation) {
            final uri? => () => _run(() => Clipboard.setData(ClipboardData(text: uri.toString())).asCancellable(_lifetime)),
            null => null,
          }),
          _button('Open in system browser', Icons.open_in_new_rounded, blank ? null : () => _run(_external)),
        ])),
      if (_commenting) Container(width: double.infinity, color: desktopMuted,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: const Text('Click an element or drag an area · Shift adds selections · Hold Space to browse · Esc exits',
          style: TextStyle(fontSize: 11, color: desktopSecondary))),
      if (_loading) LinearProgressIndicator(minHeight: 2,
        value: _progress > 0 ? _progress / 100 : null, color: desktopSecondary, backgroundColor: desktopMuted),
      Expanded(child: error != null
        ? _message(Icons.error_outline_rounded, 'This page could not be loaded.', error, retry: _location != null)
        : blank ? BrowserPorts(active: widget.active && widget.toolbar, discover: _page.discoverPorts,
          onOpen: (uri) => _run(() => _navigate(uri)))
        : _controller == null ? const Center(child: SizedBox.square(dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2)))
        : SizedBox(key: _pageKey, child: WebViewWidget(key: const ValueKey('browser-webview'), controller: _controller!))),
    ]));
  }
}
