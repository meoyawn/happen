import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:isolate';

import 'package:cancellation_token/cancellation_token.dart';
export 'package:cancellation_token/cancellation_token.dart';

typedef Json = Map<String, dynamic>;

String newId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Json jsonObject(Object? value) {
  if (value is! Map) throw const FormatException('Expected a JSON object');
  return Map<String, dynamic>.from(value);
}

String requiredString(Json value, String key) {
  final result = value[key];
  if (result is! String || result.isEmpty) {
    throw FormatException('Expected a nonempty "$key"');
  }
  return result;
}

void validateTaskId(String id) {
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
    throw const FormatException('Invalid task ID');
  }
}

/// Attaches cleanup for resources whose native APIs do not accept a token.
class CancellationHook with Cancellable {
  CancellationHook(CancellationToken token, this.release) {
    maybeAttach(token);
  }
  final void Function() release;
  @override
  void onCancel(Exception cancelException) {
    super.onCancel(cancelException);
    release();
  }

  void dispose() => detach();
}

class RemoteFailure implements Exception {
  const RemoteFailure(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// Bounds protocol messages and tool output before they enter another heap.
const maxFrameBytes = 2 * 1024 * 1024;
const maxToolOutputBytes = 64 * 1024;

String clippedText(String value, [int limit = maxToolOutputBytes]) {
  final bytes = utf8.encode(value);
  if (bytes.length <= limit) return value;
  return '${utf8.decode(bytes.sublist(0, limit), allowMalformed: true)}\n[output truncated]';
}

/// Reject oversized records before buffering an unbounded unterminated line.
Stream<String> boundedLines(
  Stream<List<int>> chunks, {
  required int maxBytes,
}) async* {
  var line = <int>[];
  var afterCr = false;
  await for (final chunk in chunks) {
    for (final byte in chunk) {
      if (afterCr && byte == 10) {
        afterCr = false;
        continue;
      }
      afterCr = false;
      if (byte == 10 || byte == 13) {
        yield utf8.decode(line);
        line = [];
        afterCr = byte == 13;
      } else {
        if (line.length >= maxBytes)
          throw const FormatException('Record exceeds byte limit');
        line.add(byte);
      }
    }
  }
  if (line.isNotEmpty) yield utf8.decode(line);
}

/// Hold the actual I/O subscription: cancelling an outer async* decoder can
/// otherwise wait for its next input before it releases a socket.
({Stream<T> stream, Future<void> Function() close}) ownStream<T>(
  Stream<T> source,
  CancellationToken cancellation,
) {
  cancellation.throwIfCancelled();
  final controller = StreamController<T>();
  StreamSubscription<T>? subscription;
  CancellationHook? hook;
  var closed = false;
  Future<void> close() async {
    if (closed) return;
    closed = true;
    hook?.dispose();
    await subscription?.cancel();
    if (!controller.isClosed) unawaited(controller.close());
  }

  subscription = source.listen(
    (value) {
      if (!closed) controller.add(value);
    },
    onError: (Object error, StackTrace stack) {
      if (!closed) controller.addError(error, stack);
    },
    onDone: () {
      hook?.dispose();
      if (!controller.isClosed) unawaited(controller.close());
    },
  );
  controller.onCancel = close;
  controller.onPause = subscription.pause;
  controller.onResume = subscription.resume;
  hook = CancellationHook(cancellation, () => unawaited(close()));
  return (stream: controller.stream, close: close);
}

Future<Object?> callIsolate(
  SendPort target,
  String method,
  Json params, {
  void Function(Json)? onEvent,
  Duration timeout = const Duration(minutes: 10),
  CancellationToken? cancellation,
}) async {
  cancellation?.throwIfCancelled();
  final port = ReceivePort();
  final result = Completer<Object?>();
  final operationId = newId();
  final deadline = TimeoutCancellationToken(timeout);
  final token = cancellation == null ? deadline : cancellation.merge(deadline);
  final subscription = port.listen((raw) {
    final message = jsonObject(raw);
    if (message.containsKey('event')) {
      onEvent?.call(jsonObject(message['event']));
    } else if (!result.isCompleted) {
      if (message.containsKey('error')) {
        result.completeError(
          message['code'] == 'cancelled'
              ? CancelledException()
              : RemoteFailure(
                  message['error'] as String,
                  code: message['code'] as String?,
                ),
        );
      } else {
        result.complete(message['result']);
      }
    }
  });
  final hook = CancellationHook(
    token,
    () => target.send({
      'method': 'cancel',
      'params': {'operation_id': operationId},
    }),
  );
  target.send({
    'method': method,
    'params': params,
    'reply': port.sendPort,
    'operation_id': operationId,
  });
  try {
    final exited = _ownerExits[target];
    return await Future.any<Object?>([
      result.future,
      if (exited != null)
        exited.then(
          (_) => throw const RemoteFailure('Worker exited before replying'),
        ),
    ]).asCancellable(token);
  } finally {
    hook.dispose();
    deadline.cancel();
    await subscription.cancel();
    port.close();
  }
}

final _ownerExits = <SendPort, Future<void>>{};

/// A worker owns its resources until its mailbox receives close.
class IsolateOwner {
  IsolateOwner._(this.isolate, this.port, this._exit, this._errors, this.done);
  final Isolate isolate;
  final SendPort port;
  final ReceivePort _exit, _errors;
  final Future<void> done;
  Future<void>? _closing;

  static Future<IsolateOwner> start(
    void Function(List<Object?>) entry,
    Json config,
  ) async {
    final ready = ReceivePort(), exit = ReceivePort(), errors = ReceivePort();
    final startup = Completer<SendPort>();
    final stopped = Completer<void>();
    errors.listen((error) {
      if (!startup.isCompleted)
        startup.completeError(StateError('Worker failed during startup'));
      if (!stopped.isCompleted) stopped.complete();
    });
    exit.listen((_) {
      if (!startup.isCompleted)
        startup.completeError(StateError('Worker exited during startup'));
      if (!stopped.isCompleted) stopped.complete();
    });
    final listener = ready.listen((message) {
      if (!startup.isCompleted) startup.complete(message as SendPort);
    });
    final isolate = await Isolate.spawn(
      entry,
      [ready.sendPort, config],
      onExit: exit.sendPort,
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
    try {
      final port = await startup.future.timeout(const Duration(seconds: 30));
      _ownerExits[port] = stopped.future;
      return IsolateOwner._(isolate, port, exit, errors, stopped.future);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      exit.close();
      errors.close();
      rethrow;
    } finally {
      await listener.cancel();
      ready.close();
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      await callIsolate(
        port,
        'close',
        {},
        timeout: const Duration(seconds: 10),
      );
      await done.timeout(const Duration(seconds: 2));
    } finally {
      _ownerExits.remove(port);
      _exit.close();
      _errors.close();
      isolate.kill();
    }
  }
}
