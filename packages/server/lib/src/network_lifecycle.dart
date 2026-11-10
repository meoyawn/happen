part of '../server.dart';

// Codex code_mode_host.rs selects a fresh generation at admission, while work
// already dispatched stays on its original generation and is never replayed.
sealed class _NetworkRecovery { const _NetworkRecovery(); }
class _NetworkIdle extends _NetworkRecovery { const _NetworkIdle(); }
class _NetworkStarting extends _NetworkRecovery {
  const _NetworkStarting(this.ready, this.cancellation);
  final Completer<IsolateOwner> ready;
  final CancellationToken cancellation;
}
class _NetworkFailed extends _NetworkRecovery {
  const _NetworkFailed(this.failure, this.retryAt);
  final RemoteFailure failure;
  final DateTime retryAt;
}
class _NetworkClosed extends _NetworkRecovery { const _NetworkClosed(); }

bool _validNetworkRecovery(_NetworkRecovery current, _NetworkRecovery next) => switch ((current, next)) {
  (_NetworkIdle() || _NetworkFailed(), _NetworkStarting() || _NetworkClosed()) => true,
  (_NetworkStarting(), _NetworkIdle() || _NetworkFailed() || _NetworkClosed()) => true,
  _ => false,
};

extension _NetworkLifecycle on AgentServer {
  void _networkTransition(_NetworkRecovery next) {
    if (!_validNetworkRecovery(_networkRecovery, next)) throw StateError('Invalid network recovery transition');
    _networkRecovery = next;
  }

  void _watchNetwork(IsolateOwner owner) {
    if (identical(_observedNetwork, owner)) return;
    _observedNetwork = owner;
    unawaited(owner.done.then((_) => _networkStopped(owner)));
  }

  void _networkStopped(IsolateOwner owner) {
    if (_closing || !identical(network, owner)) return;
    _networkExited = true;
    const failure = RemoteFailure('The local chat service stopped. An interrupted tool action may have completed; check its result before retrying.',
      code: 'network_unavailable');
    for (final token in _mcpOperations.values.toList()) { token.cancel(failure); }
    for (final task in _tasks.values) {
      if (!identical(task.turnNetwork, owner)) continue;
      task.turnCancellation?.cancel(failure);
      task.codeInterrupt?.interrupt();
      task.agent?.port.send({'method': 'cancel', 'params': <String, Object?>{}});
    }
  }

  void _networkStatus(String status) {
    for (final client in _clients) {
      client.event({'method': 'happen/network/status', 'params': {'status': status}});
    }
  }

  Future<IsolateOwner> _acquireNetwork(CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    _lifetime.throwIfCancelled();
    _watchNetwork(network);
    if (!_networkExited) return network;
    final current = _networkRecovery;
    if (current is _NetworkClosed) throw CancelledException();
    if (current is _NetworkStarting) return current.ready.future.asCancellable(cancellation);
    if (current is _NetworkFailed && DateTime.now().isBefore(current.retryAt)) {
      throw current.failure;
    }
    // A caller owns its wait, not the shared replacement. Cancelling one wait
    // cannot cancel sibling chats or create a second worker. Shutdown owns it.
    final starting = _NetworkStarting(Completer<IsolateOwner>(), CancellationToken());
    _networkTransition(starting);
    _networkStatus('recovering');
    final operation = _recoverNetwork(starting);
    _requests.add(operation);
    unawaited(operation.whenComplete(() => _requests.remove(operation)));
    return starting.ready.future.asCancellable(cancellation);
  }

  Future<void> _recoverNetwork(_NetworkStarting starting) async {
    final cancellation = starting.cancellation.merge(_lifetime);
    IsolateOwner? replacement;
    try {
      await network.close();
      cancellation.throwIfCancelled();
      final config = _networkConfiguration, generation = newId();
      replacement = await startNetwork(directory,
        endpoint: config['endpoint'] as String?, apiKeyEnv: config['api_key_env'] as String?,
        openCodeEndpoint: config['opencode_endpoint'] as String?, openCodeSearchEndpoint: config['opencode_search_endpoint'] as String?,
        publicUrl: config['public_url'] as String?, configPath: config['config_path'] as String?, skillsHome: config['skills_home'] as String?,
        events: _networkEvents.sendPort, generation: generation, cancellation: cancellation);
      cancellation.throwIfCancelled();
      if (!identical(_networkRecovery, starting)) throw CancelledException();
      network = replacement;
      _networkGeneration = generation;
      _networkExited = false;
      _watchNetwork(replacement);
      _networkTransition(const _NetworkIdle());
      starting.ready.complete(replacement);
      _networkStatus('ready');
      // Restore durable watches, not an interrupted model/tool operation.
      final restoring = _restoreMcpEvents(resumePending: false);
      _requests.add(restoring);
      unawaited(restoring.catchError((Object error) {
        if (!_closing) traceError(error);
      }).whenComplete(() => _requests.remove(restoring)));
    } catch (error, stack) {
      if (replacement != null && !identical(network, replacement)) {
        try { await replacement.close(); } catch (cleanupError) { traceError(cleanupError); }
      }
      if (identical(_networkRecovery, starting)) {
        _networkTransition(_NetworkFailed(RemoteFailure('Could not reconnect the local chat service: ${traceErrorMessage(error)}',
          code: 'network_unavailable'), DateTime.now().add(const Duration(seconds: 1))));
        _networkStatus('unavailable');
      }
      if (!starting.ready.isCompleted) starting.ready.completeError(error, stack);
    } finally { starting.cancellation.cancel(); }
  }

  Future<Object?> _callNetwork(String method, Json params, {
    CancellationToken? cancellation, void Function(Json)? onEvent,
    Duration? timeout = const Duration(minutes: 10),
  }) async {
    final token = cancellation == null ? _lifetime : cancellation.merge(_lifetime);
    final owner = await _acquireNetwork(token);
    token.throwIfCancelled();
    return callIsolate(owner.port, method, params, cancellation: token, onEvent: onEvent, timeout: timeout);
  }

  void _closeNetworkRecovery() {
    final current = _networkRecovery;
    if (current is _NetworkClosed) return;
    _networkTransition(const _NetworkClosed());
    if (current is _NetworkStarting) current.cancellation.cancel();
  }
}
