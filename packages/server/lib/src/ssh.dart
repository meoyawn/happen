part of '../server.dart';

List<String> sshOptions(String host, {String? user, int? port, String? identityFile}) {
  if (!RegExp(r'^[a-zA-Z0-9:][a-zA-Z0-9_.:-]*$').hasMatch(host)) throw ArgumentError('Enter an SSH hostname or config alias');
  if (user != null && !RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$').hasMatch(user)) throw ArgumentError('Invalid SSH username');
  if (port != null && (port < 1 || port > 65535)) throw ArgumentError('SSH port must be between 1 and 65535');
  if (identityFile != null && (identityFile.isEmpty || RegExp(r'[\x00\r\n]').hasMatch(identityFile))) throw ArgumentError('Invalid SSH key path');
  return ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
    if (user != null) ...['-l', user], if (port != null) ...['-p', '$port'],
    if (identityFile != null) ...['-i', identityFile, '-o', 'IdentitiesOnly=yes']];
}

/// SSH, the forward, the WebSocket and all cleanup stay in this worker.
Future<AgentClient> connectSsh(String alias, {String? user, int? port, String? identityFile, required CancellationToken cancellation}) async {
  sshOptions(alias, user: user, port: port, identityFile: identityFile);
  final events = ReceivePort();
  final owner = await IsolateOwner.start(_sshMain, {'alias': alias, 'user': user, 'port': port,
    'identityFile': identityFile, 'events': events.sendPort}, service: 'ssh');
  try {
    await callIsolate(owner.port, 'connect', {}, cancellation: cancellation, timeout: const Duration(seconds: 60));
    cancellation.throwIfCancelled();
    return AgentClient._worker(owner, events);
  } catch (_) { events.close(); await owner.close(); rethrow; }
}

Future<void> _sshMain(List<Object?> arguments) async {
  final config = jsonObject(arguments[1]), port = ReceivePort();
  final alias = config['alias'] as String, events = config['events'] as SendPort;
  var identity = config['identityFile'] as String?;
  if (identity?.startsWith('~/') == true) identity = '${Platform.environment['HOME']}/${identity!.substring(2)}';
  final options = sshOptions(alias, user: config['user'] as String?, port: config['port'] as int?, identityFile: identity);
  final operations = <String, CancellationToken>{};
  AgentClient? client;
  Directory? directory;
  Process? tunnel;
  Future<int>? tunnelExit;
  StreamSubscription<Json>? subscription;
  final pending = <Future<void>>{};
  var closing = false;

  Future<void> connect(CancellationToken cancellation) async {
    if (client != null) throw StateError('Already connected');
    final probe = await Process.start('ssh', [...options, '--', alias, '.local/bin/happen-server daemon start']);
    final hook = CancellationHook(cancellation, () => probe.kill());
    String output;
    try {
      await probe.stdin.close();
      final text = utf8.decoder.bind(probe.stdout).join();
      final errors = probe.stderr.drain<void>();
      final code = await probe.exitCode;
      output = await text;
      await errors;
      cancellation.throwIfCancelled();
      if (code != 0) throw StateError('Remote daemon unavailable over SSH ($code)');
    } finally { hook.dispose(); }
    final descriptor = jsonObject(jsonDecode(output));
    final socket = descriptor['socketPath'];
    if (descriptor['backend'] != 'pid' || !{'started', 'alreadyRunning'}.contains(descriptor['status']) ||
        socket is! String || !socket.startsWith('/') || socket.contains(':') || RegExp(r'[\x00-\x1f]').hasMatch(socket)) {
      throw StateError('The remote did not report a managed Happen daemon socket');
    }
    directory = await Directory.systemTemp.createTemp('hpn-');
    final local = '${directory!.path}/s';
    tunnel = await Process.start('ssh', [...options, '-N', '-o', 'ExitOnForwardFailure=yes',
      '-o', 'StreamLocalBindUnlink=no', '-L', '$local:$socket', '--', alias]);
    await tunnel!.stdin.close();
    final drained = Future.wait([tunnel!.stdout.drain<void>(), tunnel!.stderr.drain<void>()]);
    tunnelExit = tunnel!.exitCode.then((code) async { await drained; events.send(null); return code; });
    final cancel = CancellationHook(cancellation, () => tunnel?.kill());
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (await FileSystemEntity.type(local) == FileSystemEntityType.notFound) {
        cancellation.throwIfCancelled();
        if (DateTime.now().isAfter(deadline)) throw StateError('SSH socket forwarding timed out');
        await cancellableDelay(const Duration(milliseconds: 50), cancellation);
      }
      client = await AgentClient.connect(Uri(scheme: 'unix', path: local), sharedFilesystem: false, cancellation: cancellation);
      subscription = client!.events.stream.listen(events.send, onDone: () => events.send(null));
    } finally { cancel.dispose(); }
  }

  Future<void> handle(Json request) async {
    final reply = request['reply'] as SendPort?;
    final token = CancellationToken(), id = request['operation_id'] as String;
    operations[id] = token;
    try {
      final params = jsonObject(request['params']);
      Object? result;
      if (request['method'] == 'connect') { await connect(token); }
      else {
        result = await (client ?? (throw StateError('Not connected')))._request(params['method'] as String,
          jsonObject(params['params']), cancellation: token, timeout: Duration(milliseconds: params['timeout'] as int));
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
      closing = true;
      for (final token in operations.values.toList()) { token.cancel(); }
      closed.complete(request['reply'] as SendPort?);
      return;
    }
    if (closing) return;
    final operation = handle(request);
    pending.add(operation);
    unawaited(operation.whenComplete(() => pending.remove(operation)));
  });
  final reply = await closed.future;
  await Future.wait(pending.toList());
  await subscription?.cancel();
  await client?.close();
  tunnel?.kill();
  if (tunnelExit != null) await tunnelExit;
  if (directory != null) await directory!.delete(recursive: true);
  port.close();
  reply?.send({'result': null});
}
