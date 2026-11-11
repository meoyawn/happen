import '../protocol.dart';

Json sessionTokens(Json usage) {
  final read = usage['cached_input_tokens'] as num? ?? 0;
  final write = usage['cache_write_tokens'] as num? ?? 0;
  final reasoning = usage['reasoning_tokens'] as num? ?? 0;
  return {
    'input': ((usage['input_tokens'] as num? ?? 0) - read - write).clamp(0, double.maxFinite),
    'output': ((usage['output_tokens'] as num? ?? 0) - reasoning).clamp(0, double.maxFinite),
    'reasoning': reasoning, 'cache': {'read': read, 'write': write},
  };
}

num sessionTokenTotal(Json tokens) => (tokens['input'] as num? ?? 0) +
  (tokens['output'] as num? ?? 0) + (tokens['reasoning'] as num? ?? 0) +
  (tokens['cache']?['read'] as num? ?? 0) + (tokens['cache']?['write'] as num? ?? 0);
