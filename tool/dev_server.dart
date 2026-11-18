import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:config/web.dart';
import 'package:server/server.dart' show AgentClient;
import 'package:yaml/yaml.dart';

import 'download_asset.dart';

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
  final selectedRuntime = File('${cache.path}/dev-runtime');
  final path = '${File(dart).parent.path}:/usr/bin:/bin:${Platform.environment['PATH'] ?? ''}';
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  Future<String> run(String executable, List<String> args) async {
    cancellation.throwIfCancelled();
    final child = await Process.start(executable, args, workingDirectory: root, environment: {'PATH': path});
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
  Future<String> server(List<String> args) async {
    if (!await runtime.exists() || jsonObject(jsonDecode(await runtime.readAsString()))['mode'] != 'dev' ||
        !await selectedRuntime.exists()) {
      return run('$home/.local/bin/happen-server', args);
    }
    final packages = (await selectedRuntime.readAsString()).trim();
    return run(dart, ['--packages=$packages', entry, ...args]);
  }
  String quote(String value) => '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('%', '%%')}"';
  String unit(String description, String command, {String? connectorPath}) => '''[Unit]
Description=$description
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=${root.replaceAll(' ', r'\x20').replaceAll('%', '%%')}
Environment=${quote('PATH=$path')}
${connectorPath == null ? '' : 'Environment=${quote('HAPPEN_CLOUDFLARED_PATH=$connectorPath')}'}
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
  Future<String> prepareNativeRuntime() async {
    final packageConfig = File('$root/.dart_tool/package_config.json');
    final original = jsonObject(jsonDecode(await packageConfig.readAsString()));
    final resolved = {...original, 'packages': [
      for (final value in original['packages'] as List)
        {...jsonObject(value), 'rootUri': packageConfig.uri.resolve(requiredString(jsonObject(value), 'rootUri')).toString()},
    ]};
    final manifest = loadYaml(await File('$root/.dart_tool/native_assets.yaml').readAsString()) as YamlMap;
    final assets = (manifest['native-assets'] as YamlMap)['linux_x64'] as YamlMap;
    if (assets.isEmpty) throw StateError('The server native build produced no Linux x64 assets');
    final binaries = <String, List<int>>{};
    for (final id in assets.keys.cast<String>().toList()..sort()) {
      if (!id.startsWith('package:')) throw StateError('Invalid native asset ID $id');
      final package = id.substring('package:'.length).split('/').first;
      final outputs = Directory('$root/.dart_tool/hooks_runner/$package');
      if (!await outputs.exists()) throw StateError('No build hook output for $id');
      File? newest;
      DateTime? modified;
      await for (final candidate in outputs.list()) {
        if (candidate is! Directory) continue;
        final output = File('${candidate.path}/output.json');
        if (!await output.exists()) continue;
        final report = jsonObject(jsonDecode(await output.readAsString()));
        if (report['status'] != 'success') continue;
        for (final asset in report['assets'] as List? ?? const []) {
          final encoding = jsonObject(jsonObject(asset)['encoding']);
          if (encoding['id'] != id || encoding['file'] is! String) continue;
          final file = File(encoding['file'] as String);
          if (!await file.exists()) continue;
          final time = (await output.stat()).modified;
          if (modified == null || time.isAfter(modified)) { newest = file; modified = time; }
        }
      }
      if (newest == null) throw StateError('The native build did not produce $id');
      binaries[id] = await newest.readAsBytes();
    }
    final architecture = switch (Abi.current()) {
      Abi.linuxX64 => 'x64', Abi.linuxArm64 => 'arm64',
      _ => throw UnsupportedError('The development connector requires Linux x64 or arm64'),
    };
    final connectorAsset = cloudflaredAssets[architecture]!;
    final cloudflared = await downloadAsset(connectorAsset, cancellation);
    final fingerprint = sha256.convert(utf8.encode(jsonEncode([
      resolved, connectorAsset.sha256,
      {for (final entry in binaries.entries) entry.key: sha256.convert(entry.value).toString()},
    ]))).toString();
    final versions = Directory('${cache.path}/native-runtimes');
    await versions.create(recursive: true);
    final destination = Directory('${versions.path}/$fingerprint');
    if (!await destination.exists()) {
      final staging = await versions.createTemp('.pending-');
      try {
        final lib = Directory('${staging.path}/lib');
        await lib.create();
        final paths = <String, List<String>>{};
        for (final entry in binaries.entries) {
          final name = switch (entry.key.split('/').first) {
            'package:code_mode' => 'libcode_mode.so',
            'package:sqlite3' => 'libsqlite3.so',
            'package:flutter_pty2' => 'libflutter_pty2.so',
            _ => throw StateError('Unrecognized server native asset ${entry.key}'),
          };
          final path = '${destination.path}/lib/$name';
          await File('${lib.path}/$name').writeAsBytes(entry.value, flush: true);
          paths[entry.key] = ['absolute', path];
        }
        await File('${staging.path}/package_config.json').writeAsString(jsonEncode(resolved), flush: true);
        await File('${staging.path}/native_assets.yaml').writeAsString(jsonEncode({
          'format-version': [1, 0, 0], 'native-assets': {'linux_x64': paths},
        }), flush: true);
        final connector = await cloudflared.copy('${staging.path}/cloudflared');
        await run('chmod', ['500', connector.path]);
        try { await staging.rename(destination.path); }
        on FileSystemException { if (!await destination.exists()) rethrow; }
      } finally { if (await staging.exists()) await staging.delete(recursive: true); }
    }
    final packages = File('${destination.path}/package_config.json');
    if (!await packages.exists() || !await File('${destination.path}/native_assets.yaml').exists() ||
        !await File('${destination.path}/cloudflared').exists()) {
      throw StateError('The private Dart runtime is incomplete');
    }
    await cache.create(recursive: true);
    final pending = File('${selectedRuntime.path}.pending');
    await pending.writeAsString(packages.path, flush: true);
    await pending.rename(selectedRuntime.path);
    return packages.path;
  }
  Future<void> prepare() async {
    if (!Platform.isLinux) throw UnsupportedError('The managed development server targets Linux');
    // Build native hooks, then pin their libraries and package map outside the
    // shared .dart_tool directory before compiling the long-lived VM process.
    await run(dart, ['run', entry, '--version']);
    final packages = await prepareNativeRuntime();
    await units.create(recursive: true); await cache.create(recursive: true);
    await File('${units.path}/happen-server-dev.service').writeAsString(unit('Happen Dart VM server, web and tunnel supervisor',
      '${quote(dart)} --packages=${quote(packages)} --no-dds --enable-vm-service=8181/127.0.0.1 '
      '--write-service-info=${quote('${cache.path}/server-vm.json')} ${quote(entry)} _serve --data-dir ${quote(directory)}',
      connectorPath: '${File(packages).parent.path}/cloudflared'), flush: true);
    await systemctl(['daemon-reload']);
  }
  Future<void> selectMode(String mode) async {
    await Directory(directory).create(recursive: true);
    final pending = File('${runtime.path}.pending');
    await pending.writeAsString(jsonEncode({'mode': mode}), flush: true);
    await run('chmod', ['600', pending.path]);
    await pending.rename(runtime.path);
  }
  Future<void> removeOldUnits() async {
    for (final name in ['happen-web-dev.service', 'happen-web.service', 'happen-tunnel.service']) {
      final file = File('${units.path}/$name');
      if (await file.exists()) await file.delete();
    }
    final gateway = File('${cache.path}/gateway-dev.service');
    if (await gateway.exists()) await gateway.delete();
    final webVm = File('${cache.path}/web-vm.json');
    if (await webVm.exists()) await webVm.delete();
    await systemctl(['daemon-reload']);
  }
  Future<List<Json>> activeThreads() async {
    final client = await AgentClient.connect(Uri(scheme: 'unix', path: '$directory/server.sock'), cancellation: cancellation);
    try {
      final active = <Json>[];
      String? cursor;
      do {
        final page = await client.sessionRead('thread/list', {'limit': 100, 'archived': false, 'cursor': ?cursor}, cancellation: cancellation);
        active.addAll((page['data'] as List).map(jsonObject).where((thread) => thread['status']?['type'] == 'active'));
        cursor = page['nextCursor'] as String?;
      } while (cursor != null);
      return active;
    } finally { await client.close(); }
  }
  Future<bool> busy() async => (await activeThreads()).isNotEmpty;
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
      if (!await frames.moveNext().asCancellable(token)) throw StateError('Public WebSocket closed during authentication');
      final authentication = jsonObject(jsonDecode(frames.current as String));
      if (authentication['type'] != 'authenticated') {
        throw StateError('Public WebSocket authentication failed (${authentication['type']})');
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
    final terminalDeadline = TimeoutCancellationToken(const Duration(seconds: 20));
    final terminalToken = cancellation.merge(terminalDeadline);
    final terminal = await AgentClient.connect(Uri(scheme: 'unix', path: '$directory/server.sock'),
      cancellation: terminalToken);
    final terminalId = newId();
    try {
      final output = terminal.events.stream.firstWhere((event) => event['method'] == 'terminal/output' &&
        jsonObject(event['params'])['terminalId'] == terminalId).timeout(const Duration(seconds: 10));
      await terminal.terminalRequest('terminal/open', {
        'terminalId': terminalId, 'cwd': home, 'command': 'printf HAPPEN_PTY_OK',
        'columns': 80, 'rows': 24,
      }, cancellation: terminalToken);
      final event = await output;
      if (!requiredString(jsonObject(event['params']), 'data').contains('HAPPEN_PTY_OK')) {
        throw StateError('The offscreen terminal returned unexpected output');
      }
      stdout.writeln('Offscreen terminal opened and returned expected output.');
    } finally {
      try { await terminal.terminalRequest('terminal/close', {'terminalId': terminalId}, cancellation: terminalToken); }
      finally { await terminal.close(); terminalDeadline.cancel(); }
    }
  }
  Future<void> verifySettled() async {
    for (var attempt = 1; ; attempt++) {
      try { await verify(); return; }
      catch (error) {
        if (attempt >= 3) rethrow;
        stderr.writeln('Public handoff check $attempt failed: $error; retrying after the tunnel route settles.');
        await cancellableDelay(const Duration(seconds: 2), cancellation);
      }
    }
  }
  try {
    if (action == 'verify') {
      await verify();
    } else if (action == 'prepare') {
      await prepare();
      stdout.writeln('Prepared the single Dart VM supervisor and verified native assets. The active daemon is unchanged.');
    } else if (action == 'start') {
      await prepare();
      // A detached systemd job owns stop -> verify -> start, including when
      // the current agent turn is running inside the backend being replaced.
      final handoff = unit('Switch the single Happen daemon to development mode',
        '${quote(dart)} --packages=${quote((await selectedRuntime.readAsString()).trim())} '
        '${quote('$root/tool/dev_server.dart')} activate --when-idle')
        .replaceFirst('Type=simple', 'Type=oneshot').replaceFirst('Restart=on-failure', 'Restart=no')
        .replaceFirst('TimeoutStartSec=180', 'TimeoutStartSec=infinity');
      await File('${units.path}/happen-server-switch.service').writeAsString(handoff, flush: true);
      await systemctl(['daemon-reload']);
      await systemctl(['start', '--no-block', 'happen-server-switch.service']);
      stdout.writeln('Started the managed handoff. moonx dev-server -- status reports its result.');
    } else if (action == 'activate') {
      try {
        if (arguments.contains('--when-idle')) {
          stdout.writeln('Waiting for active turns to finish before replacing the supervisor.');
          while (await busy()) { await cancellableDelay(const Duration(seconds: 2), cancellation); }
        }
        for (final name in ['happen-web.service', 'happen-web-dev.service']) {
          if (await File('${units.path}/$name').exists()) await systemctl(['disable', '--now', name]);
        }
        await server(['daemon', 'stop', '--data-dir', directory]);
        await systemctl(['disable', 'happen-server.service']);
        await selectMode('dev');
        await systemctl(['enable', '--now', 'happen-server-dev.service']);
        stdout.writeln(await server(['daemon', 'start', '--data-dir', directory]));
        final record = jsonObject(jsonDecode(await File('$directory/daemon.json').readAsString()));
        if (record['runtime'] != 'dev' || !(await File('/proc/${record['pid']}/exe').resolveSymbolicLinks()).contains('/dart')) {
          throw StateError('The selected daemon is not the development VM');
        }
        if (await File('${units.path}/happen-tunnel.service').exists()) {
          await systemctl(['disable', '--now', 'happen-tunnel.service']);
        }
        await verifySettled();
        await removeOldUnits();
        stdout.writeln('One Dart VM supervisor owns the backend, web gateway and Cloudflare connector.');
      } catch (_) {
        await systemctl(['disable', '--now', 'happen-server-dev.service']);
        await selectMode('release');
        await systemctl(['enable', '--now', 'happen-server.service']);
        rethrow;
      }
    } else if (action == 'status') {
      stdout.writeln(await server(['daemon', 'status', '--data-dir', directory]));
      final active = await activeThreads();
      stdout.writeln('Active turns: ${jsonEncode([for (final thread in active) {
        'id': thread['id'], 'name': thread['name'], 'updatedAt': thread['updatedAt'],
      }])}');
      stdout.writeln(await systemctl(['show', 'happen-server-dev.service', 'happen-server.service',
        '-p', 'Id', '-p', 'ActiveState', '-p', 'MainPID']));
      stdout.writeln('Loopback VM service metadata: ${cache.path}/server-vm.json');
    } else if (action == 'release') {
      await systemctl(['stop', 'happen-server-switch.service']);
      while (await busy()) { await cancellableDelay(const Duration(seconds: 2), cancellation); }
      await server(['daemon', 'stop', '--data-dir', directory]);
      await systemctl(['disable', 'happen-server-dev.service']);
      await selectMode('release');
      await systemctl(['enable', '--now', 'happen-server.service']);
      await server(['daemon', 'start', '--data-dir', directory]);
      await verifySettled();
      stdout.writeln('The installed AOT supervisor owns the backend, web gateway and Cloudflare connector.');
    } else { throw ArgumentError('Expected start, prepare, status, verify, activate, or release'); }
  } finally { cancellation.cancel(); for (final signal in signals) { await signal.cancel(); } }
}
