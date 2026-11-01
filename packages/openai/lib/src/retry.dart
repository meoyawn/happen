import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ai/ai.dart' show ModelFailure;
import 'package:protocol/protocol.dart';

// Codex 67f0994b, codex-client/retry.rs and core/responses_retry.rs: four request
// retries, five stream retries, and a separate wait for unavailable networks.
const requestMaxRetries = 4;
const streamMaxRetries = 5;

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
  milliseconds: (200 * (1 << retries) * (.9 + Random().nextDouble() * .2)).floor(),
);

bool transportFailure(Object error) => switch (error) {
  SocketException() || HandshakeException() || HttpException() ||
  WebSocketException() || TimeoutException() => true,
  _ => false,
};

class ResponseFailure extends ModelFailure {
  const ResponseFailure(super.code, super.message, {
    this.status, this.retryAfter, this.retryStream = false,
  });
  final int? status;
  final RetryAdvice? retryAfter;
  final bool retryStream;
}

Future<T> retryRequest<T>(Future<T> Function() send, CancellationToken cancellation) async {
  for (var retries = 0; ; retries++) {
    cancellation.throwIfCancelled();
    try {
      return await send();
    } catch (error) {
      cancellation.throwIfCancelled();
      final retryable = transportFailure(error) ||
          error is ResponseFailure && error.status != null && error.status! >= 500 && error.status! <= 599;
      if (!retryable || retries >= requestMaxRetries) rethrow;
      final advice = error is ResponseFailure ? error.retryAfter : null;
      await cancellableDelay(advice == null ? retryBackoff(retries) : remainingDelay(advice), cancellation);
    }
  }
}
