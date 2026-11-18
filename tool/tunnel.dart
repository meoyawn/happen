import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import 'package:protocol/protocol.dart';
import 'web_deployment.dart';

Future<void> main(List<String> arguments) async {
  final cancellation = CancellationToken();
  final settings = await readWebDeployment(cancellation);
  final account = requiredString(settings, 'account'), zone = requiredString(settings, 'zone');
  final hostname = requiredString(settings, 'server_hostname');
  final webOrigin = Uri.https(requiredString(settings, 'hostname')).origin;
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  final home = Platform.environment['HOME']!;
  final secrets = Directory('$home/.secrets/happen');
  final root = Directory.current.absolute.path;

  Future<String> run(String executable, List<String> args, {Map<String, String>? environment}) async {
    cancellation.throwIfCancelled();
    final child = await Process.start(executable, args, environment: environment);
    final hook = CancellationHook(cancellation, () => child.kill());
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    try {
      final code = await child.exitCode.asCancellable(cancellation);
      final text = await output;
      final error = await errors;
      if (code != 0) throw StateError('$executable ${args.take(2).join(' ')} failed ($code): ${clippedText(error, 2000)}');
      return text.trim();
    } finally { hook.dispose(); child.kill(); }
  }
  Future<Object?> cf(List<String> args) async => jsonDecode(await run('cf', args,
    environment: {'CLOUDFLARE_ACCOUNT_ID': account}));
  Future<void> privateFile(String name, String content) async {
    final file = File('${secrets.path}/$name');
    await file.writeAsString(content, flush: true);
    await run('chmod', ['600', file.path]);
  }
  try {
    await secrets.create(recursive: true);
    await run('chmod', ['700', secrets.path]);
    if (await secrets.resolveSymbolicLinks() == root || (await secrets.resolveSymbolicLinks()).startsWith('$root/')) {
      throw StateError('Secrets must be outside the checkout');
    }
    final command = arguments.firstOrNull ?? 'status';
    if (command == 'provision') {
      final identity = jsonObject(await cf(['auth', 'whoami']));
      if (identity['authenticated'] != true || !(identity['accounts'] as List).any((value) => (value as Map)['id'] == account)) {
        throw StateError('Sign in to cf with the configured account first');
      }
      final tunnels = (await cf(['tunnels', 'list', '--name', 'happen-1', '--is-deleted=false']) as List).map(jsonObject).toList();
      final Json tunnel;
      if (tunnels.isEmpty) {
        await cf(['tunnels', 'create', '--name', 'happen-1', '--config-source', 'cloudflare', '--dry-run']);
        tunnel = jsonObject(await cf(['tunnels', 'create', '--name', 'happen-1', '--config-source', 'cloudflare']));
      } else { tunnel = tunnels.single; }
      final id = requiredString(tunnel, 'id');
      if (tunnel['account_tag'] != null && tunnel['account_tag'] != account) throw StateError('Tunnel belongs to another account');
      // Capture credentials directly to the private home directory. Neither
      // tokens nor create responses are printed or written in the checkout.
      final token = await cf(['tunnels', 'token', 'get', id]);
      if (token is! String || token.isEmpty) throw StateError('Cloudflare did not return a tunnel token');
      await privateFile('tunnel-token', '$token\n');
      final config = jsonEncode({'config': {'ingress': [
        {'hostname': hostname, 'service': 'http://127.0.0.1:8787'}, {'service': 'http_status:404'},
      ]}});
      await cf(['tunnels', 'config', 'update', id, '--body', config, '--dry-run']);
      await cf(['tunnels', 'config', 'update', id, '--body', config]);
      final records = (await cf(['dns', 'records', 'list', '--zone', zone, '--name', hostname]) as List).map(jsonObject).toList();
      final destination = '$id.cfargotunnel.com';
      if (records.isEmpty) {
        final record = jsonEncode({'type': 'CNAME', 'name': hostname, 'content': destination, 'proxied': true, 'ttl': 1});
        await cf(['dns', 'records', 'create', '--zone', zone, '--body', record, '--dry-run']);
        await cf(['dns', 'records', 'create', '--zone', zone, '--body', record]);
      } else if (records.length != 1 || records.single['content'] != destination || records.single['proxied'] != true) {
        throw StateError('$hostname already has a different DNS record');
      }
      final owner = File('${secrets.path}/owner-key');
      if (!await owner.exists()) {
        final random = Random.secure();
        await privateFile('owner-key', '${base64Url.encode(List.generate(32, (_) => random.nextInt(256)))}\n');
      }
      final metadata = Directory('$home/.config/happen');
      await metadata.create(recursive: true);
      await File('${metadata.path}/tunnel.json').writeAsString(jsonEncode({'account': account, 'zone': zone,
        'hostname': hostname, 'tunnel': id}), flush: true);
      stdout.writeln('Provisioned https://$hostname (named tunnel $id). Credentials are in ${secrets.path}.');
    } else if (command == 'install') {
      for (final name in ['owner-key', 'tunnel-token']) {
        if (!await File('${secrets.path}/$name').exists()) throw StateError('Run moonx deploy-tunnel provision first');
      }
      final artifact = File('build/server/linux-x64/happen-server');
      if (!await artifact.exists()) throw StateError('Run moonx build-server first');
      final checksum = (await sha256.bind(artifact.openRead()).first).toString();
      final report = jsonObject(jsonDecode(await File('build/server/linux-x64/build-report.json').readAsString()));
      if (report['sha256'] != checksum) throw StateError('The server artifact failed checksum verification');
      final release = Directory('$home/.local/share/happen/releases/$checksum');
      await release.create(recursive: true);
      final executable = '${release.path}/happen-server';
      await artifact.copy('$executable.pending');
      await run('chmod', ['755', '$executable.pending']);
      await File('$executable.pending').rename(executable);
      await run(executable, ['--version']);
      final nativeCache = Platform.environment['HAPPEN_NATIVE_CACHE'] ??
        '${Platform.environment['XDG_CACHE_HOME'] ?? '$home/.cache'}/dev.happen/cli/native';
      await run('$nativeCache/${requiredString(report, 'nativeId')}/cloudflared', ['--version']);
      final current = '$home/.local/share/happen/current';
      await Link('$current.pending').create(release.path);
      await Link('$current.pending').rename(current);
      final bin = '$home/.local/bin/happen-server';
      await Directory('$home/.local/bin').create(recursive: true);
      if (!await Link(bin).exists()) await Link(bin).create('$current/happen-server');
      final config = File('$home/.config/happen/config.yaml');
      await config.parent.create(recursive: true);
      final source = await config.exists() ? await config.readAsString() : '';
      final values = loadYaml(source) as YamlMap?;
      final web = <String, Object?>{if (values?['web'] case final Map<Object?, Object?> previous)
        ...previous.map((key, value) => MapEntry(key as String, value)),
        'public_url': 'https://$hostname', 'owner_key_file': '${secrets.path}/owner-key',
        'allowed_origins': <String>{
          webOrigin,
          ...(values?['web']?['allowed_origins'] as List? ?? const []).cast<String>(),
        }.toList(),
      }..remove('directory');
      var updated = _configValue(source, 'web', web);
      if (values?['tunnel'] == null) updated = _configValue(updated, 'tunnel', {'token_file': '${secrets.path}/tunnel-token'});
      if (updated != source) { await config.writeAsString(updated, flush: true); await run('chmod', ['600', config.path]); }
      final runtime = File('$home/.local/share/agent-server/runtime.json');
      final units = Directory('$home/.config/systemd/user');
      await units.create(recursive: true);
      String quote(String value) => '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('%', '%%')}"';
      await File('${units.path}/happen-server.service').writeAsString('''[Unit]
Description=Happen AOT server, web and tunnel supervisor
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=${home.replaceAll(' ', r'\x20').replaceAll('%', '%%')}
ExecStart=${quote(bin)} _serve --data-dir ${quote('$home/.local/share/agent-server')}
Restart=on-failure
RestartSec=2
SuccessExitStatus=130 143
TimeoutStopSec=35
UMask=0077

[Install]
WantedBy=default.target
''', flush: true);
      await run('loginctl', ['enable-linger', Platform.environment['USER']!]);
      await run('systemctl', ['--user', 'daemon-reload']);
      if (await runtime.exists() && jsonObject(jsonDecode(await runtime.readAsString()))['mode'] == 'dev') {
        stdout.writeln('Installed the release supervisor. The selected Dart VM supervisor remains active.');
        return;
      }
      for (final name in ['happen-web.service', 'happen-tunnel.service', 'happen-web-dev.service']) {
        if (await File('${units.path}/$name').exists()) {
          await run('systemctl', ['--user', 'disable', '--now', name]);
        }
      }
      await run(bin, ['daemon', 'stop']);
      await runtime.parent.create(recursive: true);
      final pending = File('${runtime.path}.pending');
      await pending.writeAsString(jsonEncode({'mode': 'release'}), flush: true);
      await run('chmod', ['600', pending.path]);
      await pending.rename(runtime.path);
      await run('systemctl', ['--user', 'enable', '--now', 'happen-server.service']);
      await run(bin, ['daemon', 'start']);
      final readyBy = DateTime.now().add(const Duration(seconds: 40));
      var ready = false;
      while (!ready && DateTime.now().isBefore(readyBy)) {
        cancellation.throwIfCancelled();
        final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final deadline = TimeoutCancellationToken(const Duration(seconds: 4));
        final hook = CancellationHook(cancellation.merge(deadline), () => http.close(force: true));
        try {
          final request = await http.getUrl(Uri.parse('https://$hostname/auth/session'));
          request.headers.set('Origin', webOrigin);
          final response = await request.close();
          ready = response.statusCode == 401 && response.headers.value('access-control-allow-origin') == webOrigin;
          await response.drain<void>();
        } catch (_) { cancellation.throwIfCancelled(); }
        finally { hook.dispose(); deadline.cancel(); http.close(force: true); }
        if (!ready) await cancellableDelay(const Duration(seconds: 1), cancellation);
      }
      if (!ready) throw StateError('Services started, but the public tunnel has not passed its authentication/CORS readiness check');
      for (final name in ['happen-web.service', 'happen-tunnel.service', 'happen-web-dev.service']) {
        final obsolete = File('${units.path}/$name');
        if (await obsolete.exists()) await obsolete.delete();
      }
      await run('systemctl', ['--user', 'daemon-reload']);
      stdout.writeln('Enabled one Happen supervisor across logout and reboot: https://$hostname');
    } else if (command == 'status') {
      stdout.writeln(await run('systemctl', ['--user', 'show', 'happen-server.service', 'happen-server-dev.service',
        '-p', 'Id', '-p', 'ActiveState', '-p', 'MainPID']));
    } else { throw ArgumentError('Expected provision, install, or status'); }
  } finally { cancellation.cancel(); for (final signal in signals) { await signal.cancel(); } }
}

String _configValue(String source, String field, Json value) {
  final root = loadYamlNode(source);
  if (root is YamlMap) {
    final key = root.nodes.keys.where((node) => node.value == field).firstOrNull;
    if (key != null) {
      final node = root.nodes[key] as YamlNode;
      return source.replaceRange(key.span.start.offset as int, node.span.end.offset, '$field: ${jsonEncode(value)}\n');
    }
  }
  return '$source\n$field: ${jsonEncode(value)}\n';
}
