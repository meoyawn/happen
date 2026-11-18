import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;

import 'appearance.dart';
import 'browser_page.dart';
import 'browser_ports.dart';

export 'browser_page.dart' show BrowserPage, browserAddress, browserHostIsLocal, browserLocationAllowed;

class ConversationBrowserScope extends InheritedWidget {
  const ConversationBrowserScope({super.key, required this.onOpen, required super.child});
  final ValueChanged<Uri> onOpen;
  static bool open(BuildContext context, Uri uri) {
    final scope = context.getInheritedWidgetOfExactType<ConversationBrowserScope>();
    if (scope == null) return false;
    scope.onOpen(uri); return true;
  }
  @override
  bool updateShouldNotify(ConversationBrowserScope oldWidget) => onOpen != oldWidget.onOpen;
}

Future<void> openDesktopLink(BuildContext context, String href, {required String directory, required CancellationToken cancellation}) async {
  cancellation.throwIfCancelled();
  final uri = Uri.tryParse(href);
  if (uri == null || !{'https', 'http', 'mailto'}.contains(uri.scheme)) return;
  if (uri.scheme != 'mailto' && !browserLocationAllowed(uri)) return;
  if (browserHostIsLocal(uri.host) && ConversationBrowserScope.open(context, uri)) return;
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
}

class DesktopBrowser extends StatefulWidget {
  const DesktopBrowser({super.key, this.initialUrl = '', this.active = true,
    this.navigationEnabled = true, this.toolbar = true, this.page, this.onPageChanged, this.directory, this.onNewTab});
  final String initialUrl;
  final bool active, navigationEnabled, toolbar;
  final BrowserPage? page;
  final VoidCallback? onNewTab;
  final String? directory;
  final void Function(String url, String title)? onPageChanged;
  @override
  State<DesktopBrowser> createState() => _DesktopBrowserState();
}
class _DesktopBrowserState extends State<DesktopBrowser> {
  final _lifetime = CancellationToken();
  final _address = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'Browser address');
  late BrowserPage _page;
  String? _addressError;

  @override
  void initState() {
    super.initState();
    _addressFocus.addListener(_syncAddress);
    _attachPage();
  }

  void _attachPage() {
    _page = widget.page ?? BrowserPage(initialUrl: widget.initialUrl);
    _page.addListener(_pageChanged);
    _syncAddress();
    if (widget.active) _start();
  }

  void _start() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      unawaited(_page.start(cancellation: _lifetime));
    });
  }

  @override
  void didUpdateWidget(DesktopBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || widget.page == null && oldWidget.initialUrl != widget.initialUrl) {
      _page.removeListener(_pageChanged);
      if (oldWidget.page == null) _page.close();
      _attachPage();
    } else if (widget.active && !oldWidget.active) { _start(); }
  }

  void _syncAddress() {
    if (!_addressFocus.hasFocus) _address.text = _page.blank ? '' : _page.location.toString();
  }

  void _pageChanged() {
    _syncAddress();
    widget.onPageChanged?.call(_page.location?.toString() ?? '', _page.title);
    setState(() => _addressError = null);
  }

  void _navigate(Uri uri) {
    if (!widget.navigationEnabled || _page.state is BrowserClosed) return;
    _addressFocus.unfocus();
    unawaited(_page.navigate(uri, cancellation: _lifetime));
  }

  void _submit(String value) {
    try { _navigate(browserAddress(value)); }
    on FormatException catch (error) { setState(() => _addressError = error.message); }
  }

  void _reload() {
    if (_page.location case final uri?) _navigate(uri);
  }

  @override
  void dispose() {
    _lifetime.cancel();
    _page.removeListener(_pageChanged);
    if (widget.page == null) _page.close();
    _addressFocus.dispose();
    _address.dispose();
    super.dispose();
  }

  Widget _button(String label, IconData icon, VoidCallback? action) => SizedBox.square(dimension: 28,
    child: IconButton(tooltip: label, onPressed: action, padding: EdgeInsets.zero, icon: Icon(icon, size: 16),
      style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: desktopSecondary)));

  Widget _content() {
    if (_page.error case final error?) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min,
        children: [Text(error, textAlign: TextAlign.center),
          if (!_page.blank) TextButton(onPressed: _reload, child: const Text('Try again'))])));
    }
    if (_page.loading) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(height: 12), Text('Connecting to dev server…'),
      ]));
    }
    if (_page.blank) {
      final discover = _page.discoverPorts;
      return discover == null || !widget.toolbar
        ? const Center(child: Text('Enter a URL to open a website.'))
        : BrowserPorts(active: widget.active, onOpen: _navigate, discover: discover);
    }
    final url = _page.loadAddress;
    if (url == null) return const SizedBox.shrink();
    return HtmlElementView.fromTagName(key: ValueKey((_page, _page.generation)), tagName: 'iframe',
      onElementCreated: (element) {
        final frame = element as web.HTMLIFrameElement;
        frame.title = _page.title;
        frame.style.border = '0';
        frame.style.width = '100%';
        frame.style.height = '100%';
        frame.referrerPolicy = 'no-referrer';
        frame.setAttribute('sandbox', url.origin == Uri.base.origin
          ? 'allow-scripts allow-forms' : 'allow-scripts allow-forms allow-same-origin allow-popups');
        frame.src = url.toString();
      });
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    if (widget.toolbar) Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: desktopBorder, width: .5))),
      child: Row(children: [
        _button(_page.loading ? 'Stop loading' : 'Reload page', _page.loading ? Icons.close_rounded : Icons.refresh_rounded,
          _page.blank || !widget.navigationEnabled ? null : _page.loading ? _page.stop : _reload),
        const SizedBox(width: 6),
        Expanded(child: TextField(key: const ValueKey('browser-address'), controller: _address, focusNode: _addressFocus,
          readOnly: !widget.navigationEnabled, onSubmitted: _submit,
          style: const TextStyle(fontSize: 12, color: desktopForeground),
          decoration: InputDecoration(hintText: 'Enter a URL', isDense: true, filled: true, fillColor: desktopMuted,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none)),
          onTap: () => _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length))),
        const SizedBox(width: 6),
        _button('Open in new tab', Icons.open_in_new_rounded, switch (_page.loadAddress) {
          final url? => () => web.window.open(url.toString(), '_blank', 'noopener,noreferrer'),
          null => null,
        }),
      ])),
    if (_addressError case final error?) Padding(padding: const EdgeInsets.all(8),
      child: Text(error, style: const TextStyle(fontSize: 12, color: desktopError))),
    Expanded(child: _content()),
  ]);
}
