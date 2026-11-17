import 'dart:async';
import '../protocol.dart';

/// Browser APIs own asynchronous I/O. Pure client computations yield to the
/// event loop, with the caller retaining cancellation and stale-result checks.
Future<T> computeCancellable<T>(FutureOr<T> Function() action, CancellationToken cancellation, {String? debugName}) {
  cancellation.throwIfCancelled();
  return Future<T>(action).asCancellable(cancellation);
}

Future<T> runIsolateEffect<T>(
  Future<T> Function(Json, CancellationToken, void Function(Json)) effect,
  Json params, {
  required CancellationToken cancellation,
  void Function(Json)? onEvent,
  Duration? timeout = const Duration(minutes: 10),
}) async {
  final deadline = timeout == null ? null : TimeoutCancellationToken(timeout);
  final token = deadline == null ? cancellation : cancellation.merge(deadline);
  try {
    token.throwIfCancelled();
    return await effect(params, token, (event) {
      if (!token.isCancelled) onEvent?.call(event);
    }).asCancellable(token);
  } finally { deadline?.cancel(); }
}
