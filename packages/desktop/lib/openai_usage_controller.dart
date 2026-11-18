import 'package:flutter/foundation.dart';
import 'package:openai/account_usage.dart';
import 'package:protocol/protocol.dart';

typedef OpenAIUsageNotice = ({String message, bool error});

sealed class _UsageState {
  const _UsageState(this.usage, this.notice);
  final OpenAIAccountUsage? usage;
  final OpenAIUsageNotice? notice;
}

final class _Idle extends _UsageState { const _Idle() : super(null, null); }
final class _Loading extends _UsageState { const _Loading(super.usage, [super.notice]); }
final class _Ready extends _UsageState {
  const _Ready(OpenAIAccountUsage super.usage, super.notice);
}
final class _Redeeming extends _UsageState {
  const _Redeeming(OpenAIAccountUsage usage) : super(usage, null);
}
final class _Failed extends _UsageState {
  const _Failed(OpenAIAccountUsage? usage, String message) : super(usage, (message: message, error: true));
}

_UsageState _transition(_UsageState current, _UsageState next) => switch ((current, next)) {
  (_, _Idle()) => next,
  (_Idle() || _Ready() || _Failed(), _Loading()) => next,
  (_Ready() || _Failed(), _Redeeming()) => next,
  (_Loading(), _Ready() || _Failed()) => next,
  (_Redeeming(), _Loading() || _Failed()) => next,
  _ => throw StateError('Invalid OpenAI usage transition'),
};

class OpenAIUsageController extends ChangeNotifier {
  OpenAIUsageController(this._request, {required this.onRedemption});
  final Future<Json> Function(String method, Json params, {required CancellationToken cancellation}) _request;
  final ValueChanged<OpenAIUsageNotice> onRedemption;

  _UsageState _state = const _Idle();
  CancellationToken? _operation;
  final _redeemRequestIds = <(String, String?), String>{};
  bool _disposed = false;

  OpenAIAccountUsage? get usage => _state.usage;
  OpenAIUsageNotice? get notice => _state.notice;
  bool get redeeming => _state is _Redeeming;
  bool get busy => redeeming || _state is _Loading;

  void _set(_UsageState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed || busy) return;
    final token = _operation = CancellationToken();
    _set(_Loading(usage));
    await _load(token);
  }

  Future<void> _load(CancellationToken token) async {
    final previous = usage, outcome = notice;
    try {
      final reply = await _request(openAIUsageReadMethod, {}, cancellation: token);
      if (!identical(_operation, token)) return;
      _set(_Ready(OpenAIAccountUsage.fromJson(reply), outcome));
    } catch (_) {
      if (!identical(_operation, token)) return;
      _set(_Failed(previous, '${outcome == null ? '' : '${outcome.message} '}Couldn’t load current usage.'));
    } finally { _finish(token); }
  }

  Future<void> redeem(OpenAIAccountUsage snapshot, OpenAIUsageReset reset) async {
    if (_disposed || busy || !identical(snapshot, usage) || !snapshot.resets.contains(reset)) return;
    // A lost response leaves the request ID available for retrying this credit.
    final credit = (snapshot.accountScope, reset.id);
    final requestId = _redeemRequestIds.putIfAbsent(credit, newUuidV7);
    final token = _operation = CancellationToken();
    _set(_Redeeming(snapshot));
    late final OpenAIUsageNotice outcome;
    try {
      final reply = await _request(openAIUsageResetMethod, {
        'account_scope': snapshot.accountScope, 'credit_id': ?reset.id, 'redeem_request_id': requestId,
      }, cancellation: token);
      if (!identical(_operation, token)) return;
      outcome = switch (reply['code']) {
        'reset' => (message: 'Usage limits reset.', error: false),
        'nothing_to_reset' => (message: 'Your usage doesn’t need a reset right now.', error: false),
        'already_redeemed' => (message: 'This reset has already been used.', error: false),
        'no_credit' => (message: 'This reset is no longer available.', error: true),
        'account_changed' => (message: 'The ChatGPT account changed.', error: true),
        _ => throw const FormatException('Unknown ChatGPT reset result'),
      };
    } catch (_) {
      if (!identical(_operation, token)) return;
      const message = 'Couldn’t confirm the reset. Try using it again.';
      _set(_Failed(snapshot, message));
      _finish(token);
      onRedemption((message: message, error: true));
      return;
    }
    _redeemRequestIds.remove(credit);
    _set(_Loading(null, outcome));
    onRedemption(outcome);
    await _load(token);
  }

  void _finish(CancellationToken token) {
    if (identical(_operation, token)) _operation = null;
    token.cancel();
  }

  void invalidate({bool accountChanged = false}) {
    if (_disposed) return;
    if (accountChanged) _redeemRequestIds.clear();
    if (_operation case final token?) _finish(token);
    if (_state is! _Idle) _set(const _Idle());
  }

  @override
  void dispose() {
    _disposed = true;
    if (_operation case final token?) _finish(token);
    super.dispose();
  }
}
