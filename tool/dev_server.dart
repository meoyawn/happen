import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:config/web.dart';
import 'package:server/server.dart' show AgentClient;

// The systemd handoff runs outside the old daemon's process tree. Stopping
// that daemon therefore cannot cancel the operation that starts its successor.
Future<void> main(List<String> arguments) async {
  final action = arguments.firstOrNull ?? 'start';
  final root = File.fromUri(Platform.script).parent.parent.path;
  final home = Platform.environment['HOME']!;
  final directory = Platform.environment['AGENT_DATA_DIR'] ?? '$home/.local/share/agent-server';
  final units = Directory('$home/.config/systemd/user');
  final cache = Directory('$home/.cache/happen');
  final dart = Platform.resolvedExecutable;
  final entry = '$root/packages/server/bin/happen_server.dart';
  final runtime = File('$directory/runtime.json');
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  Future<String> run(String executable, List<String> args) async {
    cancellation.throwIfCancelled();
    final child = await Process.start(executable, args, workingDirectory: root);
    final hook = CancellationHook(cancellation, () => child.kill());
    final output = child.stdout.transform(utf8.decoder).join(), errors = child.stderr.transform(utf8.decoder).join();
    try {
      final code = await child.exitCode.asCancellable(cancellation);
      final text = await output, error = await errors;
      if (code != 0) throw StateError('$executable ${args.take(3).join(' ')} failed: ${clippedText(error, 2500)}');
      return text.trim();
    } finally { hook.dispose(); child.kill(); }
  }
  Future<String> systemctl(List<String> args) => run('systemctl', ['--user', ...args]);
  String quote(String value) => '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('%', '%%')}"';
  final path = '${File(dart).parent.path}:/usr/bin:/bin:${Platform.environment['PATH'] ?? ''}';
  String unit(String description, String command, {String after = 'network-online.target', String? wants}) => '''[Unit]
Description=$description
After=$after
${wants == null ? '' : 'Wants=$wants'}
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=${root.replaceAll(' ', r'\x20').replaceAll('%', '%%')}
Environment=${quote('PATH=$path')}
ExecStart=$command
Restart=on-failure
RestartSec=2
SuccessExitStatus=130 143
TimeoutStopSec=35
TimeoutStartSec=180
UMask=0077

[Install]
WantedBy=default.target
''';
  Future<void> prepare() async {
    if (!Platform.isLinux) throw UnsupportedError('The managed development server targets Linux');
    // Resolve native hooks without starting a second backend.
    await run(dart, ['run', entry, '--version']);
    await units.create(recursive: true); await cache.create(recursive: true);
    await File('${units.path}/happen-server-dev.service').writeAsString(unit('Happen Dart VM development backend',
      '${quote(dart)} --enable-vm-service=8181/127.0.0.1 --write-service-info=${quote('${cache.path}/server-vm.json')} '
      'run ${quote(entry)} _serve --data-dir ${quote(directory)}'), flush: true);
    await File('${cache.path}/gateway-dev.service').writeAsString(unit('Happen Dart VM development web gateway',
      '${quote(dart)} --enable-vm-service=8182/127.0.0.1 --write-service-info=${quote('${cache.path}/web-vm.json')} '
      'run ${quote(entry)} web --socket ${quote('$directory/server.sock')}',
      after: 'network-online.target happen-server-dev.service', wants: 'happen-server-dev.service'), flush: true);
    await systemctl(['daemon-reload']);
  }
  Future<bool> busy() async {
    final client = await AgentClient.connect(Uri(scheme: 'unix', path: '$directory/server.sock'), cancellation: cancellation);
    try {
      String? cursor;
      do {
        final page = await client.sessionRead('thread/list', {'limit': 100, 'archived': false, 'cursor': ?cursor}, cancellation: cancellation);
        if ((page['data'] as List).any((value) => jsonObject(value)['status']?['type'] == 'active')) return true;
        cursor = page['nextCursor'] as String?;
      } while (cursor != null);
      return false;
    } finally { await client.close(); }
  }
  Future<void> verify() async {
    final config = await loadWebConfiguration(cancellation: cancellation);
    final origin = config.allowedOrigins.where((origin) => origin.startsWith('https://')).first;
    final server = Uri.parse(config.publicUrl!);
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final deadline = TimeoutCancellationToken(const Duration(seconds: 45));
    final token = cancellation.merge(deadline);
    WebSocket? socket;
    StreamIterator<dynamic>? frames;
    final hook = CancellationHook(token, () { http.close(force: true); unawaited(socket?.close()); });
    Future<Json> request(String path, Json body) async {
      final request = await http.postUrl(server.resolve(path)).asCancellable(token);
      request.headers.set('Origin', origin); request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().asCancellable(token);
      final text = await response.transform(utf8.decoder).join().asCancellable(token);
      if (response.statusCode != 200 && response.statusCode != 204) throw StateError('Public gateway $path failed (${response.statusCode})');
      return text.isEmpty ? {} : jsonObject(jsonDecode(text));
    }
    String? session;
    try {
      var ready = false;
      while (!ready) {
        token.throwIfCancelled();
        try {
          final request = await http.getUrl(server.resolve('/auth/session')).asCancellable(token);
          request.headers.set('Origin', origin);
          final response = await request.close().asCancellable(token);
          ready = response.statusCode == 401 && response.headers.value('access-control-allow-origin') == origin;
          await response.drain<void>().asCancellable(token);
        } on SocketException { token.throwIfCancelled(); }
        on HttpException { token.throwIfCancelled(); }
        if (!ready) await cancellableDelay(const Duration(seconds: 1), token);
      }
      final key = (await File(config.ownerKeyFile).readAsString()).trim();
      session = requiredString(await request('/auth/login', {'key': key}), 'token');
      socket = await WebSocket.connect(server.replace(scheme: 'wss', path: '/ws').toString(),
        headers: {'Origin': origin}).asCancellable(token);
      frames = StreamIterator<dynamic>(socket);
      socket.add(jsonEncode({'type': 'authenticate', 'token': session}));
      if (!await frames.moveNext().asCancellable(token) || jsonObject(jsonDecode(frames.current as String))['type'] != 'authenticated') {
        throw StateError('Public WebSocket authentication failed');
      }
      socket.add(jsonEncode({'id': 1, 'method': 'initialize', 'params': {
        'clientInfo': {'name': 'happen-dev-handoff', 'version': '0.1.0'}, 'capabilities': {'experimentalApi': true},
      }}));
      if (!await frames.moveNext().asCancellable(token)) throw StateError('The backend closed before initialization');
      final reply = jsonObject(jsonDecode(frames.current as String));
      if (reply['id'] != 1 || !reply.containsKey('result')) throw StateError('The backend did not initialize through the public tunnel');
      stdout.writeln('Public owner authentication, WSS and backend initialization passed.');
    } finally {
      await socket?.close(); await frames?.cancel();
      if (session != null) { try { await request('/auth/logout', {'token': session}); } catch (_) {} }
      hook.dispose(); deadline.cancel(); http.close(force: true);
    }
  }
  try {
    if (action == 'verify') {
      await verify();
    } else if (action == 'prepare') {
      await prepare();
      stdout.writeln('Prepared Dart VM units and native hooks. The active daemon is unchanged.');
    } else if (action == 'web') {
      await prepare();
      await run(dart, ['run', entry, 'daemon', 'start', '--data-dir', directory]);
      final gateway = File('${units.path}/happen-web-dev.service');
      final source = (await File('${cache.path}/gateway-dev.service').readAsString()).replaceAll('happen-server-dev.service', '');
      await gateway.writeAsString(source.replaceFirst('[Service]',
        '[Service]\nExecStartPre=${quote(dart)} run ${quote(entry)} daemon start --data-dir ${quote(directory)}'), flush: true);
      await systemctl(['stop', 'happen-web.service']);
      await systemctl(['disable', 'happen-web.service']);
      final connector = File('${units.path}/happen-tunnel.service');
      await connector.writeAsString((await connector.readAsString()).replaceAll('happen-web.service', 'happen-web-dev.service'), flush: true);
      await systemctl(['daemon-reload']);
      await systemctl(['enable', '--now', 'happen-web-dev.service']);
      stdout.writeln('The gateway supports hot reload. The one existing backend daemon is unchanged.');
    } else if (action == 'start') {
      await prepare();
      // A detached systemd job owns stop -> verify -> start, including when
      // the current agent turn is running inside the backend being replaced.
      final handoff = unit('Switch the single Happen daemon to development mode',
        '${quote(dart)} --disable-dart-dev ${quote('$root/tool/dev_server.dart')} activate --when-idle')
        .replaceFirst('Type=simple', 'Type=oneshot').replaceFirst('Restart=on-failure', 'Restart=no')
        .replaceFirst('TimeoutStartSec=180', 'TimeoutStartSec=infinity');
      await File('${units.path}/happen-server-switch.service').writeAsString(handoff, flush: true);
      await systemctl(['daemon-reload']);
      await systemctl(['start', '--no-block', 'happen-server-switch.service']);
      stdout.writeln('Started the managed handoff. moonx dev-server -- status reports its result.');
    } else if (action == 'activate') {
      try {
      if (arguments.contains('--when-idle')) {
        stdout.writeln('Waiting for active turns to finish before replacing the backend.');
        while (await busy()) { await cancellableDelay(const Duration(seconds: 2), cancellation); }
      }
      await systemctl(['stop', 'happen-web.service', 'happen-web-dev.service']);
      await systemctl(['disable', 'happen-web.service']);
      // Existing PID identity checks wait for the release process to exit.
      await run(dart, ['run', entry, 'daemon', 'stop', '--data-dir', directory]);
      await Directory(directory).create(recursive: true);
      final pending = File('${runtime.path}.pending');
      await pending.writeAsString(jsonEncode({'mode': 'dev'}), flush: true);
      await run('chmod', ['600', pending.path]); await pending.rename(runtime.path);
      final connector = File('${units.path}/happen-tunnel.service');
      await connector.writeAsString((await connector.readAsString()).replaceAll('happen-web.service', 'happen-web-dev.service'), flush: true);
      await File('${cache.path}/gateway-dev.service').copy('${units.path}/happen-web-dev.service');
      await systemctl(['daemon-reload']);
      await systemctl(['enable', '--now', 'happen-server-dev.service']);
      stdout.writeln(await run(dart, ['run', entry, 'daemon', 'start', '--data-dir', directory]));
      final record = jsonObject(jsonDecode(await File('$directory/daemon.json').readAsString()));
      if (record['runtime'] != 'dev' || !(await File('/proc/${record['pid']}/exe').resolveSymbolicLinks()).contains('/dart')) {
        throw StateError('The selected daemon is not the development VM');
      }
      await systemctl(['enable', '--now', 'happen-web-dev.service', 'happen-tunnel.service']);
      await verify();
      stdout.writeln('One Dart VM backend is active; the release backend has stopped.');
      } catch (_) {
        await systemctl(['disable', '--now', 'happen-web-dev.service', 'happen-server-dev.service']);
        if (await runtime.exists()) await runtime.delete();
        final connector = File('${units.path}/happen-tunnel.service');
        await connector.writeAsString((await connector.readAsString()).replaceAll('happen-web-dev.service', 'happen-web.service'), flush: true);
        await systemctl(['daemon-reload']);
        await systemctl(['enable', '--now', 'happen-web.service']);
        rethrow;
      }
    } else if (action == 'status') {
      stdout.writeln(await run(dart, ['run', entry, 'daemon', 'status', '--data-dir', directory]));
      stdout.writeln('Active turns: ${await busy()}');
      stdout.writeln(await systemctl(['show', 'happen-server-dev.service', 'happen-web-dev.service', 'happen-tunnel.service',
        '-p', 'Id', '-p', 'ActiveState', '-p', 'MainPID']));
      stdout.writeln('Loopback VM service metadata: ${cache.path}/{server,web}-vm.json');
    } else if (action == 'release') {
      await systemctl(['stop', 'happen-server-switch.service']);
      await systemctl(['disable', '--now', 'happen-web-dev.service', 'happen-server-dev.service']);
      if (await runtime.exists()) await runtime.delete();
      final connector = File('${units.path}/happen-tunnel.service');
      await connector.writeAsString((await connector.readAsString()).replaceAll('happen-web-dev.service', 'happen-web.service'), flush: true);
      await systemctl(['daemon-reload']);
      await systemctl(['enable', '--now', 'happen-web.service']);
      stdout.writeln('Restored the installed release backend and web gateway.');
    } else { throw ArgumentError('Expected start, web, prepare, status, activate, or release'); }
  } finally { cancellation.cancel(); for (final signal in signals) { await signal.cancel(); } }
}
