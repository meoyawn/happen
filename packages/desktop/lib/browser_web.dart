import 'dart:async';
import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;
import 'browser_page_web.dart';
export 'browser_page_web.dart';

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
  late final _page = widget.page ?? BrowserPage(initialUrl: widget.initialUrl);
  late final _address = TextEditingController(text: _page.location?.toString() ?? '');
  final _lifetime = CancellationToken();
  @override
  void dispose() { _lifetime.cancel(); _address.dispose(); if (widget.page == null) _page.close(); super.dispose(); }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _page, builder: (context, _) => Column(children: [
    if (widget.toolbar) Row(children: [Expanded(child: TextField(controller: _address,
      decoration: const InputDecoration(hintText: 'https://example.com', isDense: true),
      onSubmitted: (value) { try { unawaited(_page.navigate(browserAddress(value), cancellation: _lifetime)); } on FormatException { /* Keep the current page. */ } })),
      IconButton(tooltip: 'Open in new tab', icon: const Icon(Icons.open_in_new, size: 18), onPressed: _page.location == null ? null
        : () => web.window.open(_page.location.toString(), '_blank', 'noopener,noreferrer'))]),
    Expanded(child: _page.blank ? const Center(child: Text('Open a website')) : HtmlElementView.fromTagName(
      key: ValueKey(_page.location.toString()), tagName: 'iframe', onElementCreated: (element) {
        final frame = element as web.HTMLIFrameElement;
        frame.src = _page.location.toString(); frame.style.border = '0'; frame.style.width = '100%'; frame.style.height = '100%';
        frame.referrerPolicy = 'no-referrer';
        frame.setAttribute('sandbox', 'allow-scripts allow-forms allow-same-origin allow-popups');
      })),
  ]));
}
