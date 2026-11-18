import 'package:protocol/protocol.dart';

const openAIUsageReadMethod = 'openai.usage';
const openAIUsageResetMethod = 'openai.usage.reset';
const openAIUsageMethods = {openAIUsageReadMethod, openAIUsageResetMethod};

typedef OpenAIUsageWindow = ({int seconds, int percentLeft, DateTime? resetsAt});
typedef OpenAIUsageReset = ({String? id, String title, String? description, DateTime? expiresAt});

class OpenAIAccountUsage {
  OpenAIAccountUsage.fromJson(Json data)
    : accountScope = requiredString(data, 'account_scope'),
      plan = _text(data['plan_type']),
      windows = List.unmodifiable(_windows(data['rate_limit'])),
      unlimitedCredits = switch (data['credits']) { {'unlimited': true} => true, _ => false },
      creditBalance = _balance(data['credits']),
      resetCount = _count(data['reset_details']) ?? _count(data['rate_limit_reset_credits']),
      resets = List.unmodifiable(_resets(data['reset_details'],
        _count(data['reset_details']) ?? _count(data['rate_limit_reset_credits'])));

  final String accountScope;
  final String? plan;
  final List<OpenAIUsageWindow> windows;
  final bool unlimitedCredits;
  final num? creditBalance;
  final int? resetCount;
  final List<OpenAIUsageReset> resets;
}

String? _text(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

List<OpenAIUsageWindow> _windows(Object? value) {
  if (value is! Map) return [];
  return [
    for (final key in ['primary_window', 'secondary_window'])
      if (value[key] case {'limit_window_seconds': final int seconds, 'used_percent': final num used}
          when seconds > 0 && used.isFinite)
        (seconds: seconds, percentLeft: (100 - used).clamp(0, 100).round(),
          resetsAt: _timestamp(value[key]['reset_at'])),
  ]..sort((a, b) => a.seconds.compareTo(b.seconds));
}

DateTime? _timestamp(Object? value) => value is int && value > 0 && value <= 8640000000000
  ? DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true) : null;

num? _balance(Object? value) {
  if (value is! Map) return null;
  final raw = value['balance'];
  final balance = raw is num ? raw : num.tryParse(raw is String ? raw : '');
  if (balance != null && balance.isFinite && balance >= 0) return balance;
  return value['has_credits'] == false ? 0 : null;
}

int? _count(Object? value) => switch (value) {
  {'available_count': final int count} when count >= 0 => count,
  _ => null,
};

List<OpenAIUsageReset> _resets(Object? details, int? count) {
  if (count == 0) return [];
  final credits = switch (details) { {'credits': final List<Object?> values} => values, _ => const <Object?>[] };
  final resets = <String, OpenAIUsageReset>{
    for (final credit in credits)
      if (credit case {'id': final String id} when id.isNotEmpty)
        id: (id: id, title: _text(credit['title']) ?? 'Usage limit reset',
          description: _text(credit['description']),
          expiresAt: DateTime.tryParse(_text(credit['expires_at']) ?? '')),
  };
  if (resets.isEmpty && count == 1) {
    return [(id: null, title: 'Usage limit reset', description: null, expiresAt: null)];
  }
  return resets.values.toList()..sort((a, b) => (a.expiresAt?.millisecondsSinceEpoch ?? 8640000000000000)
    .compareTo(b.expiresAt?.millisecondsSinceEpoch ?? 8640000000000000));
}
