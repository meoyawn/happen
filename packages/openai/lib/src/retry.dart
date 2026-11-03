import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ai/ai.dart' show ModelFailure;
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

// Match Codex's independent HTTP and Responses stream budgets.
const maxRequestRetries = 4;
const maxStreamRetries = 5;

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
    this.status, this.retryAfter, this.retryable = false,
  });
  final int? status;
  final RetryAdvice? retryAfter;
  final bool retryable;
}

Future<T> retryRequest<T>(Future<T> Function() send, CancellationToken cancellation, {
  void Function(Json)? onEvent,
}) async {
  for (var retries = 0; ; retries++) {
    cancellation.throwIfCancelled();
    try {
      return await traceAsync('openai.http.attempt', send, category: 'model', attributes: {'attempt': retries + 1});
    } catch (error) {
      cancellation.throwIfCancelled();
      // HTTP retries precede provider error classification, as in codex-client.
      final retryable = transportFailure(error) ||
        error is ResponseFailure && error.status != null && error.status! >= 500 && error.status! <= 599;
      if (!retryable || retries >= maxRequestRetries) rethrow;
      await _waitForRetry(error, retries + 1, maxRequestRetries, 'http', cancellation, onEvent);
    }
  }
}

Future<T> retryResponseStream<T>(Future<T> Function() send, CancellationToken cancellation, {
  required bool unboundedConnections,
  bool Function()? fallbackTransport,
  void Function(Json)? onEvent,
}) async {
  var retries = 0;
  var connectionRetries = 0;
  var connectionDelay = const Duration(seconds: 5);
  while (true) {
    cancellation.throwIfCancelled();
    try {
      return await traceAsync('openai.stream.attempt', send, category: 'model', attributes: {'attempt': retries + 1});
    } catch (error) {
      cancellation.throwIfCancelled();
      final retryable = transportFailure(error) || switch (error) {
        ResponseFailure(:final retryable) => retryable,
        ModelFailure(:final code) => {'stream_disconnected', 'stream_idle_timeout'}.contains(code),
        FormatException() => true,
        _ => false,
      };
      if (!retryable) rethrow;
      if (unboundedConnections && (error is SocketException || error is HandshakeException || error is HttpException)) {
        await _waitForRetry(error, ++connectionRetries, null, 'connection', cancellation, onEvent,
          delay: connectionDelay, message: 'Reconnecting… waiting for network');
        connectionDelay = Duration(seconds: min(60, connectionDelay.inSeconds * 2));
        continue;
      }
      if (retries >= maxStreamRetries) {
        if (fallbackTransport?.call() != true) rethrow;
        // Switching transport cannot bypass the provider's original deadline.
        await _waitForRetry(error, 1, 1, 'fallback', cancellation, onEvent,
          delay: Duration.zero, message: 'Switching to HTTPS');
        retries = 0;
        continue;
      }
      await _waitForRetry(error, ++retries, maxStreamRetries, 'stream', cancellation, onEvent);
    }
  }
}

Future<void> _waitForRetry(Object error, int attempt, int? maxRetries, String layer,
  CancellationToken cancellation, void Function(Json)? onEvent, {Duration? delay, String? message}) async {
  final advice = error is ResponseFailure ? error.retryAfter : null;
  delay = advice == null ? delay ?? retryBackoff(attempt - 1) : remainingDelay(advice);
  traceInstant('openai.retry', category: 'retry', attributes: {
    'attempt': attempt, 'delay_ms': delay.inMilliseconds, 'retry.layer': layer,
    'error.type': error.runtimeType.toString(),
    if (error is ResponseFailure) 'http.response.status_code': error.status,
  });
  final count = '$attempt${maxRetries == null ? '' : '/$maxRetries'}';
  onEvent?.call({'type': 'model.retrying', 'attempt': attempt, 'layer': layer,
    if (maxRetries != null) 'max_retries': maxRetries,
    'delay_ms': delay.inMilliseconds,
    if (advice != null) 'provider_delay': true,
    if (error is ResponseFailure) 'error': {
      'code': error.code, 'message': error.message,
      if (error.status != null) 'http_status': error.status,
    },
    'message': message ?? (error is ResponseFailure ? 'Retrying provider ($count)' : 'Reconnecting… $count')});
  await traceAsync('openai.retry.wait',
    () => cancellableDelay(advice == null ? delay! : remainingDelay(advice), cancellation), category: 'retry',
    attributes: {'retry.layer': layer});
}
