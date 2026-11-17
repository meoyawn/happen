import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';

Uri browserAddress(String input) {
  final value = input.trim();
  if (value.isEmpty || value == 'about:blank') return Uri.parse('about:blank');
  final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
  if (uri == null || !browserLocationAllowed(uri)) throw const FormatException('Enter an HTTP or HTTPS address');
  return uri;
}
bool browserHostIsLocal(String host) => host == 'localhost' || host == '127.0.0.1' || host == '::1' || host.endsWith('.localhost');
bool browserLocationAllowed(Uri uri) => uri.userInfo.isEmpty && (
  {'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty || uri.toString() == 'about:blank');

sealed class BrowserPageState { const BrowserPageState(this.location); final Uri? location; }
final class BrowserDormant extends BrowserPageState { const BrowserDormant(super.location); }
final class BrowserReady extends BrowserPageState { const BrowserReady(super.location); }
final class BrowserClosed extends BrowserPageState { const BrowserClosed() : super(null); }

BrowserPageState _transition(BrowserPageState current, BrowserPageState next) => switch ((current, next)) {
  (BrowserDormant() || BrowserReady(), BrowserReady() || BrowserClosed()) => next,
  _ => throw StateError('Invalid browser page transition'),
};

class BrowserPage extends ChangeNotifier {
  BrowserPage({String initialUrl = '', this.navigationEnabled = true, this.toolbar = true, this.directory})
    : _state = BrowserDormant(initialUrl.isEmpty ? null : browserAddress(initialUrl));
  final bool navigationEnabled, toolbar;
  final String? directory;
  BrowserPageState _state;
  BrowserPageState get state => _state;
  Uri? get location => _state.location;
  String get title => location?.host ?? '';
  bool get loading => false;
  bool get blank => location == null || location.toString() == 'about:blank';
  String? get error => null;
  int generation = 0;
  Future<void> start({required CancellationToken cancellation}) async { cancellation.throwIfCancelled(); }
  Future<void> navigate(Uri uri, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    if (!browserLocationAllowed(uri)) throw const FormatException('Enter an HTTP or HTTPS address');
    _state = _transition(_state, BrowserReady(uri)); generation++; notifyListeners();
  }
  Future<Object> evaluate(String script, {required CancellationToken cancellation}) =>
    throw UnsupportedError('Browser security prevents controlling an embedded website');
  Future<void> stop() async {}
  void close() { if (_state is BrowserClosed) return; _state = _transition(_state, const BrowserClosed()); dispose(); }
}
