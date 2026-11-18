import 'package:flutter/widgets.dart';

import 'browser_native.dart' if (dart.library.js_interop) 'browser_web.dart' as platform;
import 'browser_page.dart';

export 'browser_native.dart' if (dart.library.js_interop) 'browser_web.dart' show openDesktopLink;
export 'browser_page.dart' show BrowserPage, browserAddress, browserHostIsLocal, browserLocationAllowed;

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

/// A retained browser tab, also used without the address bar for file previews.
class DesktopBrowser extends StatefulWidget {
  const DesktopBrowser({super.key, this.initialUrl = '', this.active = true,
    this.toolbar = true, this.navigationEnabled = true, this.directory, this.page, this.onPageChanged, this.onNewTab});
  final String initialUrl;
  final bool active, toolbar;
  /// File previews can use a fixed initial address.
  final bool navigationEnabled;
  final String? directory;
  final BrowserPage? page;
  final void Function(String url, String title)? onPageChanged;
  final VoidCallback? onNewTab;

  @override
  State<DesktopBrowser> createState() => platform.createDesktopBrowserState();
}
