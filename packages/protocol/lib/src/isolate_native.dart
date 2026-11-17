import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:math';
import 'package:telemetry/telemetry.dart';
import '../protocol.dart';

final _operationIds = UuidV7Ids(random: Random());

Future<Object?> callIsolate(
  SendPort target,
  String method,
  Json params, {
  void Function(Json)? onEvent,
  Duration? timeout = const Duration(minutes: 10),
  CancellationToken? cancellation,
}) => traceAsync('isolate.call $method', () => _callIsolate(target, method, params,
  onEvent: onEvent, timeout: timeout, cancellation: cancellation), category: 'isolate');

Future<Object?> _callIsolate(
  SendPort target,
  String method,
  Json params, {
  void Function(Json)? onEvent,
  Duration? timeout,
  CancellationToken? cancellation,
}) async {
  cancellation?.throwIfCancelled();
  if (timeout == null && cancellation == null) {
    throw ArgumentError('Calls without a deadline require caller cancellation');
  }
  final port = ReceivePort();
  final result = Completer<Object?>();
  // Correlation inside worker mailboxes is not an authentication credential.
  final operationId = _operationIds.create();
  final deadline = timeout == null ? null : TimeoutCancellationToken(timeout);
  final token = deadline == null ? cancellation!
      : cancellation == null ? deadline : cancellation.merge(deadline);
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
  final exited = _ownerExitSignal(target);
  final exitHook = exited == null ? null : CancellationHook(exited, () {
    if (!result.isCompleted) result.completeError(exited.exception!);
  });
  try {
    target.send({
      'method': method,
      'params': params,
      'reply': port.sendPort,
      'operation_id': operationId,
      '_trace': ?traceIsolateCarrier(method),
    });
    return await result.future.asCancellable(token);
  } finally {
    exitHook?.dispose();
    hook.dispose();
    deadline?.cancel();
    await subscription.cancel();
    port.close();
  }
}

final _ownerExits = <SendPort, Future<RemoteFailure>>{};
final _ownerExitSignals = Expando<CancellationToken>();

CancellationToken? _ownerExitSignal(SendPort target) {
  final exited = _ownerExits[target];
  if (exited == null) return null;
  final cached = _ownerExitSignals[exited];
  if (cached != null) return cached;
  final signal = CancellationToken();
  _ownerExitSignals[exited] = signal;
  // A future's listeners cannot be removed. Observe exit once per owner, then
  // let each call detach its cancellation hook as soon as it finishes.
  unawaited(exited.then(signal.cancel));
  return signal;
}

SendPort? _ownerExit;
final _exitResources = <String, Json>{};

/// Custody survives abrupt exit. Only plain data crosses the VM's exit-message
/// boundary; the parent already owns the effect that disposes these resources.
void registerIsolateCleanup(String key, Json params) {
  if (_ownerExit == null) return;
  _exitResources[key] = params;
  _publishIsolateCleanup();
}

void unregisterIsolateCleanup(String key) {
  if (_exitResources.remove(key) != null) _publishIsolateCleanup();
}

void _publishIsolateCleanup() {
  if (_ownerExit case final target?) {
    Isolate.current.addOnExitListener(target, response: {'cleanup': _exitResources.values.toList()});
  }
}

Future<void> _cleanExitedIsolate(Object? message,
  Future<void> Function(Json, CancellationToken, void Function(Json))? effect) async {
  if (effect == null || message is! Map || message['cleanup'] is! List) return;
  final cancellation = TimeoutCancellationToken(const Duration(seconds: 3));
  try {
    await Future.wait((message['cleanup'] as List).map((raw) async {
      try {
        await runIsolateEffect<void>(effect, jsonObject(raw), cancellation: cancellation);
      } catch (error, stack) { stderr.writeln('Worker resource cleanup failed: ${traceErrorMessage(error)}\n$stack'); }
    }));
  } finally { cancellation.cancel(); }
}

/// A worker owns its resources until its mailbox receives close.
class IsolateOwner {
  IsolateOwner._(this.isolate, this.port, this._exit, this.done);
  final Isolate isolate;
  final SendPort port;
  final ReceivePort _exit;
  final Future<void> done;
  Future<void>? _closing;

  static Future<IsolateOwner> start(
    Future<void> Function(List<Object?>) entry,
    Json config, {
    String service = 'network',
    CancellationToken? cancellation,
    Future<void> Function(Json, CancellationToken, void Function(Json))? cleanup,
  }
  ) async {
    cancellation?.throwIfCancelled();
    final ready = ReceivePort(), exit = ReceivePort();
    final startup = Completer<SendPort>();
    final stopped = Completer<RemoteFailure>();
    RemoteFailure? failure;
    // One lifecycle mailbox preserves the fatal error before the exit signal.
    // `done` acknowledges actual exit, rather than the earlier error notice.
    exit.listen((message) {
      if (message is List) {
        failure = RemoteFailure('$service worker failed: ${message[0]}', code: 'worker_failed');
        final stack = StackTrace.fromString('${message[1]}');
        stderr.writeln('$failure\n$stack');
        if (!startup.isCompleted) {
          startup.completeError(StateError('$service worker failed during startup: ${message[0]}'), stack);
        }
        return;
      }
      unawaited(() async {
        await _cleanExitedIsolate(message, cleanup);
        if (!startup.isCompleted) { startup.completeError(StateError('$service worker exited during startup')); }
        if (!stopped.isCompleted) {
          stopped.complete(failure ?? RemoteFailure('$service worker exited before replying', code: 'worker_exited'));
        }
      }());
    });
    final listener = ready.listen((message) {
      if (!startup.isCompleted) startup.complete(message as SendPort);
    });
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _tracedOwnerMain,
        [entry, ready.sendPort, {...config, '_trace': currentTrace?.carrier(), '_trace_service': service,
          '_owner_exit': cleanup == null ? null : exit.sendPort}],
        onExit: exit.sendPort,
        onError: exit.sendPort,
        errorsAreFatal: true,
        debugName: service,
      );
      final port = await startup.future.timeout(const Duration(seconds: 30)).asCancellable(cancellation);
      _ownerExits[port] = stopped.future;
      return IsolateOwner._(isolate, port, exit, stopped.future.then((_) {}));
    } catch (error, stack) {
      if (isolate != null) {
        isolate.kill(priority: Isolate.immediate);
        try { await stopped.future.timeout(const Duration(seconds: 5)); }
        catch (cleanupError) { stderr.writeln('Worker startup cleanup failed: ${traceErrorMessage(cleanupError)}'); }
      }
      exit.close();
      Error.throwWithStackTrace(error, stack);
    } finally {
      await listener.cancel();
      ready.close();
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    Object? failure;
    StackTrace? failureStack;
    try {
      try {
        await callIsolate(port, 'close', {}, timeout: const Duration(seconds: 10));
      } catch (error, stack) {
        if (error is! RemoteFailure || error.code != 'worker_exited' && error.code != 'worker_failed') {
          failure = error; failureStack = stack;
        }
      }
      try { await done.timeout(const Duration(seconds: 5)); }
      catch (error, stack) {
        failure ??= error; failureStack ??= stack;
        isolate.kill(priority: Isolate.immediate);
        // Keep the lifecycle mailbox until forced-exit cleanup acknowledges
        // resource disposal, even when the ordinary close request failed.
        try { await done.timeout(const Duration(seconds: 5)); }
        catch (cleanupError) { stderr.writeln('Worker forced-exit cleanup failed: ${traceErrorMessage(cleanupError)}'); }
      }
    } finally {
      unawaited(_ownerExits.remove(port));
      _exit.close();
      isolate.kill();
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }
}

/// I/O effects keep native resource setup and cleanup off their caller's
/// isolate. Cancellation reaches the effect before the worker is closed.
/// Subscriptions use a null timeout and live until their caller cancels them.
Future<T> runIsolateEffect<T>(
  Future<T> Function(Json, CancellationToken, void Function(Json)) effect,
  Json params, {
  required CancellationToken cancellation,
  void Function(Json)? onEvent,
  Duration? timeout = const Duration(minutes: 10),
}) async {
  cancellation.throwIfCancelled();
  final owner = await IsolateOwner.start(_effectMain, {'effect': effect}, service: 'effect');
  try {
    return await callIsolate(owner.port, 'run', params,
      cancellation: cancellation, onEvent: onEvent, timeout: timeout) as T;
  } finally { await owner.close(); }
}

Future<void> _effectMain(List<Object?> arguments) async {
  final effect = jsonObject(arguments[1])['effect'] as
    Future<Object?> Function(Json, CancellationToken, void Function(Json));
  final port = ReceivePort(), cancellation = CancellationToken();
  Future<void>? pending;
  var closing = false;
  (arguments[0] as SendPort).send(port.sendPort);
  port.listen((raw) {
    final request = jsonObject(raw), reply = request['reply'] as SendPort?;
    if (request['method'] == 'cancel') { cancellation.cancel(); return; }
    if (request['method'] == 'close') {
      closing = true;
      cancellation.cancel();
      unawaited((() async {
        await pending;
        reply?.send({'result': null});
        port.close();
      })());
      return;
    }
    if (request['method'] != 'run' || pending != null || closing) {
      reply?.send({'error': 'Worker effect is already running or closed'});
      return;
    }
    pending = traceIncoming(request, () async {
      try {
        cancellation.throwIfCancelled();
        final result = await effect(jsonObject(request['params']), cancellation,
          (event) => reply?.send({'event': event}));
        cancellation.throwIfCancelled();
        reply?.send({'result': result});
      } catch (error) {
        reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
      }
    }, service: 'effect');
  });
}

Future<void> _tracedOwnerMain(List<Object?> arguments) async {
  final entry = arguments[0] as Future<void> Function(List<Object?>);
  final config = jsonObject(arguments[2]);
  _ownerExit = config['_owner_exit'] as SendPort?;
  _publishIsolateCleanup();
  final context = traceContextFrom(config['_trace'], service: config['_trace_service'] as String);
  await withTrace(context, () => entry([arguments[1], config]));
}

Future<T> computeCancellable<T>(FutureOr<T> Function() action, CancellationToken cancellation, {String? debugName}) =>
  CancellableIsolate.run(action, cancellation, debugName: debugName);
