part of '../server.dart';

List<String> sshOptions(String host, {String? user, int? port, String? identityFile}) {
  if (!RegExp(r'^[a-zA-Z0-9:][a-zA-Z0-9_.:-]*$').hasMatch(host)) throw ArgumentError('Enter an SSH hostname or config alias');
  if (user != null && !RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$').hasMatch(user)) throw ArgumentError('Invalid SSH username');
  if (port != null && (port < 1 || port > 65535)) throw ArgumentError('SSH port must be between 1 and 65535');
  if (identityFile != null && (identityFile.isEmpty || RegExp(r'[\x00\r\n]').hasMatch(identityFile))) throw ArgumentError('Invalid SSH key path');
  return ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2',
    '-o', 'StrictHostKeyChecking=yes', '-o', 'UpdateHostKeys=no',
    if (user != null) ...['-l', user], if (port != null) ...['-p', '$port'],
    if (identityFile != null) ...['-i', identityFile, '-o', 'IdentitiesOnly=yes']];
}

sealed class _SshState { const _SshState(); }
final class _SshIdle extends _SshState { const _SshIdle(); }
final class _SshConnecting extends _SshState { const _SshConnecting(); }
final class _SshReady extends _SshState {
  const _SshReady(this.client, this.cancellation);
  final AgentClient client;
  final CancellationToken cancellation;
}
final class _SshRetrying extends _SshState {
  const _SshRetrying(this.error);
  final Object error;
}
final class _SshClosed extends _SshState { const _SshClosed(); }

_SshState _sshTransition(_SshState current, _SshState next) => switch ((current, next)) {
  (_SshIdle() || _SshRetrying(), _SshConnecting()) => next,
  (_SshConnecting(), _SshReady() || _SshRetrying()) => next,
  (_SshReady(), _SshRetrying()) => next,
  (_, _SshClosed()) when current is! _SshClosed => next,
  _ => throw StateError('Invalid SSH connection transition'),
};

/// Publish the worker before connecting so cached threads remain available
/// throughout startup and outages. The worker owns all transport retries.
Future<AgentClient> startSsh(String alias, {String? user, int? port, String? identityFile, required CancellationToken cancellation}) async {
  sshOptions(alias, user: user, port: port, identityFile: identityFile);
  final events = ReceivePort();
  final owner = await IsolateOwner.start(_sshMain, {'alias': alias, 'user': user, 'port': port,
    'identityFile': identityFile, 'events': events.sendPort}, service: 'ssh');
  final client = AgentClient._worker(owner, events);
  try {
    await callIsolate(owner.port, 'connect', {}, cancellation: cancellation, timeout: const Duration(seconds: 60));
    cancellation.throwIfCancelled();
    return client;
  } catch (_) { await client.close(); rethrow; }
}

Future<void> _sshMain(List<Object?> arguments) async {
  final config = jsonObject(arguments[1]), port = ReceivePort();
  final alias = config['alias'] as String, events = config['events'] as SendPort;
  var identity = config['identityFile'] as String?;
  if (identity?.startsWith('~/') == true) identity = '${Platform.environment['HOME']}/${identity!.substring(2)}';
  final options = sshOptions(alias, user: config['user'] as String?, port: config['port'] as int?, identityFile: identity);
  final lifetime = CancellationToken(), operations = <String, CancellationToken>{};
  final pending = <Future<void>>{};
  _SshState state = const _SshIdle();
  Future<void>? maintaining;

  void setState(_SshState next) { state = _sshTransition(state, next); }

  Future<void> maintain() async {
    Directory? directory;
    Process? tunnel;
    Future<int>? tunnelExit;
    CancellationToken? tunnelClosed;
    CancellationHook? cancelTunnel;
    String? local, remoteSocket;
    var delay = 1000;
    var ensureDaemonAt = DateTime.now();

    Future<void> releaseTunnel() async {
      tunnel?.kill(ProcessSignal.sigkill);
      if (tunnelExit != null) await tunnelExit;
      cancelTunnel?.dispose();
      tunnelClosed?.cancel();
      if (directory != null) await directory!.delete(recursive: true);
      directory = null; tunnel = null; tunnelExit = null;
      tunnelClosed = null; cancelTunnel = null; local = null; remoteSocket = null;
    }

    Future<String> startDaemon(CancellationToken cancellation) async {
        final probe = await Process.start('ssh', [...options, '--', alias, '.local/bin/happen-server daemon start']);
        final hook = CancellationHook(cancellation, () => probe.kill(ProcessSignal.sigkill));
        String output;
        try {
          await probe.stdin.close();
          final text = utf8.decoder.bind(probe.stdout).join();
          final errors = utf8.decoder.bind(probe.stderr).join();
          final code = await probe.exitCode;
          output = await text;
          final error = await errors;
          cancellation.throwIfCancelled();
          if (code != 0) throw StateError('Remote daemon unavailable over SSH ($code): ${error.trim()}');
        } finally { hook.dispose(); }
        final descriptor = jsonObject(jsonDecode(output));
        final socket = descriptor['socketPath'];
        if (descriptor['backend'] != 'pid' || !{'started', 'alreadyRunning'}.contains(descriptor['status']) ||
            socket is! String || !socket.startsWith('/') || socket.contains(':') || RegExp(r'[\x00-\x1f]').hasMatch(socket)) {
          throw StateError('The remote did not report a managed Happen daemon socket');
        }
        return socket;
    }

    try {
      while (!lifetime.isCancelled) {
        setState(const _SshConnecting());
        final deadline = TimeoutCancellationToken(Duration(seconds: tunnel == null ? 55 : 3));
        final cancellation = lifetime.merge(deadline);
        AgentClient? client;
        StreamSubscription<Json>? subscription;
        final connection = CancellationToken();
        final lost = Completer<void>();
        void disconnected() {
          connection.cancel();
          if (!lost.isCompleted) lost.complete();
        }
        var established = false;
        DateTime? readyAt;
        try {
          // Daemon restarts replace the remote socket, not the SSH transport.
          // Reuse the forward immediately; start a stopped daemon if it stays down.
          if (tunnel == null || DateTime.now().isAfter(ensureDaemonAt)) {
            ensureDaemonAt = DateTime.now().add(const Duration(seconds: 30));
            final socket = await startDaemon(cancellation);
            ensureDaemonAt = DateTime.now().add(const Duration(seconds: 5));
            if (remoteSocket != null && remoteSocket != socket) await releaseTunnel();
            remoteSocket = socket;
          }
          if (tunnel == null) {
            directory = await Directory.systemTemp.createTemp('hpn-');
            cancellation.throwIfCancelled();
            local = '${directory!.path}/s';
            final process = tunnel = await Process.start('ssh', [...options, '-N', '-o', 'ExitOnForwardFailure=yes',
              '-o', 'StreamLocalBindUnlink=no', '-L', '$local:$remoteSocket', '--', alias]);
            final closed = tunnelClosed = CancellationToken();
            cancelTunnel = CancellationHook(lifetime, () => process.kill(ProcessSignal.sigkill));
            final cancelConnect = CancellationHook(cancellation, () => process.kill(ProcessSignal.sigkill));
            try {
              await process.stdin.close();
              final drained = Future.wait([process.stdout.drain<void>(), process.stderr.drain<void>()]);
              tunnelExit = process.exitCode.then((code) async { closed.cancel(); await drained; return code; });
              final until = DateTime.now().add(const Duration(seconds: 15));
              while (await FileSystemEntity.type(local!) == FileSystemEntityType.notFound) {
                cancellation.throwIfCancelled();
                if (closed.isCancelled) throw StateError('SSH socket forwarding exited');
                if (DateTime.now().isAfter(until)) throw StateError('SSH socket forwarding timed out');
                await cancellableDelay(const Duration(milliseconds: 25), cancellation);
              }
            } finally { cancelConnect.dispose(); }
          }
          client = await AgentClient.connect(Uri(scheme: 'unix', path: local!), sharedFilesystem: false,
            cancellation: cancellation.merge(tunnelClosed!));
          cancellation.throwIfCancelled();
          if (tunnelClosed!.isCancelled) throw StateError('SSH socket forwarding exited');
          client.socket!.pingInterval = const Duration(seconds: 2);
          subscription = client.events.stream.listen(events.send, onDone: disconnected);
          setState(_SshReady(client, connection));
          established = true;
          readyAt = DateTime.now();
          events.send({'method': 'connection/ready'});
          deadline.cancel();
          await lost.future.asCancellable(lifetime.merge(tunnelClosed!).merge(connection));
          throw StateError('Remote connection closed');
        } catch (error) {
          if (!lifetime.isCancelled) {
            setState(_SshRetrying(error));
            events.send({'method': 'connection/closed', 'params': {'error': '$error'}});
          }
        } finally {
          connection.cancel();
          deadline.cancel();
          await subscription?.cancel();
          await client?.close();
          if (tunnelClosed?.isCancelled == true) await releaseTunnel();
        }
        if (lifetime.isCancelled) break;
        if (established) {
          if (DateTime.now().difference(readyAt!) >= const Duration(seconds: 30)) delay = 1000;
          ensureDaemonAt = DateTime.now().add(const Duration(seconds: 1));
          continue;
        }
        try { await cancellableDelay(Duration(milliseconds: delay + alias.hashCode.abs() % 26), lifetime); }
        on CancelledException { break; }
        // A rejected handshake can be an SSH admission penalty. Repeated
        // probes must leave the host time to recover instead of extending it.
        delay = (delay * 2).clamp(1000, 30000);
      }
    } finally { await releaseTunnel(); }
  }

  Future<void> handle(Json request) async {
    final reply = request['reply'] as SendPort?;
    final token = CancellationToken(), id = request['operation_id'] as String;
    operations[id] = token;
    try {
      final params = jsonObject(request['params']);
      Object? result;
      if (request['method'] == 'connect') {
        if (maintaining != null) throw StateError('Already connecting');
        maintaining = maintain();
      } else if (request['method'] == 'check') {
        final current = state;
        if (current is _SshReady) {
          try {
            await current.client._request('ping', {}, cancellation: token.merge(lifetime).merge(current.cancellation),
              timeout: const Duration(seconds: 3));
          } catch (_) {
            if (!token.isCancelled && !lifetime.isCancelled && identical(state, current)) current.cancellation.cancel();
          }
        }
      } else {
        final current = state;
        if (current is! _SshReady) throw StateError('Remote machine is reconnecting');
        final cancellation = token.merge(lifetime).merge(current.cancellation);
        try {
          result = await current.client._request(params['method'] as String,
            jsonObject(params['params']), cancellation: cancellation, timeout: Duration(milliseconds: params['timeout'] as int));
          cancellation.throwIfCancelled();
        } catch (_) {
          // Pending replies can fail before the event stream reports its close.
          // Invalidate the transport's operations before publishing stale errors.
          if (current.client.isClosed) current.cancellation.cancel();
          cancellation.throwIfCancelled();
          rethrow;
        }
      }
      reply?.send({'result': result});
    } catch (error) { reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'}); }
    finally { operations.remove(id); token.cancel(); }
  }

  (arguments[0] as SendPort).send(port.sendPort);
  final closed = Completer<SendPort?>();
  port.listen((raw) {
    final request = jsonObject(raw);
    if (request['method'] == 'cancel') { operations[request['params']['operation_id']]?.cancel(); return; }
    if (request['method'] == 'close') {
      if (lifetime.isCancelled) return;
      lifetime.cancel();
      for (final token in operations.values.toList()) { token.cancel(); }
      closed.complete(request['reply'] as SendPort?);
      return;
    }
    if (lifetime.isCancelled) return;
    final operation = handle(request);
    pending.add(operation);
    unawaited(operation.whenComplete(() => pending.remove(operation)));
  });
  final reply = await closed.future;
  await Future.wait(pending.toList());
  await maintaining;
  setState(const _SshClosed());
  port.close();
  reply?.send({'result': null});
}
