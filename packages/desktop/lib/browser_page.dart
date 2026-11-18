import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';

import 'browser_page_native.dart' if (dart.library.js_interop) 'browser_page_web.dart' as platform;
import 'connection.dart' show AgentClient;

export 'browser_page_native.dart' if (dart.library.js_interop) 'browser_page_web.dart'
  show browserAddress, browserHostIsLocal, browserLocationAllowed;

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

/// The navigation state and operations of a retained browser tab.
abstract class BrowserPage extends ChangeNotifier {
  factory BrowserPage({String initialUrl = '', bool navigationEnabled = true, bool toolbar = true,
      String? directory, AgentClient? client}) => platform.PlatformBrowserPage(initialUrl: initialUrl,
    navigationEnabled: navigationEnabled, toolbar: toolbar, directory: directory, client: client);

  @protected
  BrowserPage.platform(String initialUrl, Uri Function(String) parseAddress) {
    try { _state = BrowserDormant(initialUrl.isEmpty ? null : parseAddress(initialUrl)); }
    on FormatException catch (error) { _state = BrowserFailed(null, error.message); }
  }

  late BrowserPageState _state;
  BrowserPageState get state => _state;
  Uri? get location => _state.location;
  bool get blank => location == null || location.toString() == 'about:blank';
  bool get loading => _state is BrowserLoading;
  int get progress => switch (_state) { BrowserLoading(:final progress) => progress, _ => 100 };
  String? get error => switch (_state) { BrowserFailed(:final error) => error, _ => null };

  /// The address used to load the page, which may point to a preview tunnel.
  Uri? get loadAddress;
  String get title;
  int get generation;
  Future<List<Json>> Function({required CancellationToken cancellation})? get discoverPorts;

  @protected
  void updateState(BrowserPageState next, {bool notify = true}) {
    _state = switch ((_state, next)) {
      (_, BrowserLoading() || BrowserReady() || BrowserFailed() || BrowserClosed()) when _state is! BrowserClosed => next,
      _ => throw StateError('Invalid browser page transition'),
    };
    if (notify) notifyListeners();
  }

  Future<void> start({required CancellationToken cancellation}) async {
    if (_state is BrowserDormant && !blank) await navigate(location!, cancellation: cancellation);
  }

  Future<void> navigate(Uri uri, {required CancellationToken cancellation});
  Future<Object> evaluate(String script, {required CancellationToken cancellation});
  Future<void> stop();
  void close();
}
