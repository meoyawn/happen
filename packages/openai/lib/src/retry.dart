import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ai/ai.dart' show ModelFailure;
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

// Tool requests stay bounded; inference can recover until its caller cancels.
const maxRetryDelay = Duration(seconds: 5);

typedef RetryAdvice = ({Duration delay, Stopwatch elapsed});

RetryAdvice? retryAdvice(Object? value) {
  if (value is! String) return null;
  value = value.trim();
  final received = Stopwatch()..start();
  final seconds = RegExp(r'^\d+$').hasMatch(value) ? int.tryParse(value) : null;
  if (seconds != null) {
    // Reject intervals that cannot be represented by Dart's microsecond clock.
    if (seconds > 9223372036854) return null;
    return (delay: Duration(seconds: seconds), elapsed: received);
  }
  try {
    final delay = HttpDate.parse(value).difference(DateTime.now());
    return (delay: delay.isNegative ? Duration.zero : delay, elapsed: received);
  } on HttpException {
    return null;
  }
}

Duration remainingDelay(RetryAdvice advice) {
  final remaining = advice.delay - advice.elapsed.elapsed;
  return remaining.isNegative ? Duration.zero : remaining;
}

Duration retryBackoff(int retries) => Duration(
  milliseconds: min(30000, (200 * (1 << min(retries, 8)) * (.9 + Random().nextDouble() * .2)).floor()),
);

bool transportFailure(Object error) => switch (error) {
  SocketException() || HandshakeException() || HttpException() ||
  WebSocketException() || TimeoutException() => true,
  _ => false,
};

class ResponseFailure extends ModelFailure {
  const ResponseFailure(super.code, super.message, {
    this.status, this.retryAfter, this.retryable = false,
  });
  final int? status;
  final RetryAdvice? retryAfter;
  final bool retryable;
}

Future<T> retryRequest<T>(Future<T> Function() send, CancellationToken cancellation, {
  int? maxRetries = 2,
  void Function(Json)? onEvent,
}) async {
  for (var retries = 0; ; retries++) {
    cancellation.throwIfCancelled();
    try {
      return await traceAsync('openai.attempt', send, category: 'model', attributes: {'attempt': retries + 1});
    } catch (error) {
      cancellation.throwIfCancelled();
      final retryable = transportFailure(error) || switch (error) {
        ResponseFailure(:final retryable) => retryable,
        ModelFailure(:final code) => {'stream_disconnected', 'stream_idle_timeout'}.contains(code),
        _ => false,
      };
      if (!retryable || maxRetries != null && retries >= maxRetries) rethrow;
      final advice = error is ResponseFailure ? error.retryAfter : null;
      final delay = advice == null ? retryBackoff(retries) : remainingDelay(advice);
      traceInstant('openai.retry', category: 'retry', attributes: {
        'attempt': retries + 1, 'delay_ms': delay.inMilliseconds, 'error.type': error.runtimeType.toString(),
        if (error is ResponseFailure) 'http.response.status_code': error.status,
      });
      // Bounded tool calls return long cooldowns; inference waits cancellably.
      if (maxRetries != null && delay > maxRetryDelay) rethrow;
      onEvent?.call({'type': 'model.retrying', 'attempt': retries + 1,
        if (maxRetries != null) 'max_retries': maxRetries,
        'delay_ms': delay.inMilliseconds,
        'message': 'Reconnecting… ${retries + 1}${maxRetries == null ? '' : '/$maxRetries'}'});
      await traceAsync('openai.retry.wait',
        () => cancellableDelay(advice == null ? delay : remainingDelay(advice), cancellation), category: 'retry');
    }
  }
}
