import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'web_deployment.dart';

// cf 1.0.0-rc.1 has Pages resource commands, but its pages deploy command
// redirects users to Workers. Upload static assets through the documented Pages
// API; cf still owns authentication, project, domain and DNS operations.
Future<void> main(List<String> arguments) async {
  final cancellation = CancellationToken();
  final settings = await readWebDeployment(cancellation);
  final account = requiredString(settings, 'account'), zone = requiredString(settings, 'zone');
  final projectName = settings['project'] as String? ?? 'happen', hostname = requiredString(settings, 'hostname');
  Process? child;
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((signal) => signal.watch().listen((_) {
    cancellation.cancel(); child?.kill(); http.close(force: true);
  })).toList();
  Future<Object?> cf(List<String> args) async {
    cancellation.throwIfCancelled();
    child = await Process.start('cf', args, environment: {'CLOUDFLARE_ACCOUNT_ID': account});
    final output = child!.stdout.transform(utf8.decoder).join(), errors = child!.stderr.transform(utf8.decoder).join();
    final code = await child!.exitCode;
    final text = await output, error = await errors;
    if (code != 0) throw StateError('cf ${args.take(3).join(' ')} failed: ${clippedText(error, 1600)}');
    return jsonDecode(text);
  }
  Future<Object?> api(String method, String path, String token, [Object? body, bool multipart = false]) async {
    cancellation.throwIfCancelled();
    final deadline = TimeoutCancellationToken(const Duration(minutes: 2));
    final hook = CancellationHook(cancellation.merge(deadline), () => http.close(force: true));
    try {
      final request = await http.openUrl(method, Uri.parse('https://api.cloudflare.com/client/v4$path'));
      request.headers.set('Authorization', 'Bearer $token');
      if (multipart) {
        final boundary = 'happen-${newId()}';
        request.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
        for (final field in jsonObject(body).entries) {
          final file = field.key.startsWith('_');
          request.write('--$boundary\r\nContent-Disposition: form-data; name="${field.key}"${file ? '; filename="${field.key}"' : ''}\r\n'
            '${file ? 'Content-Type: application/octet-stream\r\n' : ''}\r\n${field.value}\r\n');
        }
        request.write('--$boundary--\r\n');
      } else if (body != null) { request.headers.contentType = ContentType.json; request.write(jsonEncode(body)); }
      final response = await request.close();
      final result = jsonObject(jsonDecode(await response.transform(utf8.decoder).join()));
      if (response.statusCode >= 400 || result['success'] != true) {
        throw StateError('Pages $method $path failed (${response.statusCode}): ${result['errors']}');
      }
      return result['result'];
    } finally { hook.dispose(); deadline.cancel(); }
  }
  try {
    final root = Directory('packages/desktop/build/web').absolute;
    if (!await File('${root.path}/index.html').exists()) throw StateError('Build the Flutter web client first');
    for (final name in ['_worker.js', '_worker.bundle', 'functions', '_routes.json']) {
      if (await FileSystemEntity.type('${root.path}/$name') != FileSystemEntityType.notFound) {
        throw StateError('The Pages deployment must contain only static files: $name');
      }
    }
    final projects = (await cf(['pages', 'list']) as List).map(jsonObject).toList();
    Json? project = projects.where((value) => value['name'] == projectName).firstOrNull;
    if (project == null) {
      final body = jsonEncode({'name': projectName, 'production_branch': 'master'});
      await cf(['pages', 'create', '--body', body, '--dry-run']);
      project = jsonObject(await cf(['pages', 'create', '--body', body]));
    }
    // Refresh through cf before reading its private credential store. Tokens
    // stay in memory and are never copied into the build output or checkout.
    await cf(['auth', 'whoami']);
    final home = Platform.environment['HOME']!;
    final token = Platform.environment['CLOUDFLARE_API_TOKEN'] ??
      jsonObject(jsonDecode(await File('$home/.config/cloudflare/config/default.json').readAsString()))['oauth_token'] as String?;
    if (token == null || token.isEmpty) throw StateError('Sign in to the pinned cf CLI before deploying');
    final jwt = requiredString(jsonObject(await api('GET', '/accounts/$account/pages/projects/$projectName/upload-token', token)), 'jwt');
    final manifest = <String, String>{}, assets = <String, Json>{};
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      cancellation.throwIfCancelled();
      if (entry is! File) continue;
      final relative = '/${entry.path.substring(root.path.length + 1).replaceAll(Platform.pathSeparator, '/')}';
      if (relative.endsWith('.map') || relative == '/_headers' || relative == '/_redirects') continue;
      final bytes = await entry.readAsBytes();
      if (bytes.length > 25 * 1024 * 1024) throw StateError('A Pages asset exceeds 25 MiB: $relative');
      final contentType = _contentType(relative);
      final hash = sha256.convert([...bytes, ...utf8.encode(contentType)]).toString().substring(0, 32);
      manifest[relative] = hash;
      assets[hash] = {'key': hash, 'value': base64Encode(bytes), 'base64': true, 'metadata': {'contentType': contentType}};
    }
    final missing = (await api('POST', '/pages/assets/check-missing', jwt, {'hashes': assets.keys.toList()}) as List).cast<String>();
    var batch = <Json>[], size = 0;
    for (final hash in missing) {
      final asset = assets[hash]!;
      final length = (asset['value'] as String).length;
      if (batch.isNotEmpty && size + length > 18 * 1024 * 1024) {
        await api('POST', '/pages/assets/upload', jwt, batch); batch = []; size = 0;
      }
      batch.add(asset); size += length;
    }
    if (batch.isNotEmpty) await api('POST', '/pages/assets/upload', jwt, batch);
    await api('POST', '/pages/assets/upsert-hashes', jwt, {'hashes': assets.keys.toList()});
    stdout.writeln('Uploaded ${missing.length} changed static assets (${manifest.length} total).');
    final deployArgs = ['pages', 'deployments', 'create', projectName, '--branch', 'master', '--commit-dirty', 'true',
      '--manifest', jsonEncode(manifest), '--redirects', '@${root.path}/_redirects'];
    await cf([...deployArgs, '--dry-run']);
    // The pinned generated CLI omits the _headers multipart field, so use the
    // same public Pages deployment API for the complete static upload form.
    var deployment = jsonObject(await api('POST', '/accounts/$account/pages/projects/$projectName/deployments', token, {
      'manifest': jsonEncode(manifest), 'branch': 'master', 'commit_dirty': 'true',
      '_headers': await File('${root.path}/_headers').readAsString(),
      '_redirects': await File('${root.path}/_redirects').readAsString(),
    }, true));
    final deploymentDeadline = DateTime.now().add(const Duration(minutes: 3));
    while (jsonObject(deployment['latest_stage'])['status'] != 'success') {
      final status = jsonObject(deployment['latest_stage'])['status'];
      if (status == 'failure' || status == 'canceled' || DateTime.now().isAfter(deploymentDeadline)) {
        throw StateError('Pages deployment did not finish successfully: $status');
      }
      await cancellableDelay(const Duration(seconds: 2), cancellation);
      deployment = jsonObject(await cf(['pages', 'deployments', 'get', requiredString(deployment, 'id'), '--project-name', projectName]));
    }
    if (deployment['uses_functions'] == true) throw StateError('Unexpected Pages Functions in the static deployment');
    final domains = (project['domains'] as List? ?? const []).cast<String>();
    if (!domains.contains(hostname)) {
      await cf(['pages', 'domains', 'create', projectName, '--name', hostname, '--dry-run']);
      await cf(['pages', 'domains', 'create', projectName, '--name', hostname]);
    }
    final records = (await cf(['dns', 'records', 'list', '--zone', zone, '--name', hostname]) as List).map(jsonObject).toList();
    final destination = requiredString(project, 'subdomain');
    final body = jsonEncode({'type': 'CNAME', 'name': hostname, 'content': destination, 'proxied': true, 'ttl': 1});
    if (records.isEmpty || records.single['type'] != 'CNAME' || records.single['content'] != destination || records.single['proxied'] != true) {
      final dns = records.isEmpty ? ['dns', 'records', 'create', '--zone', zone, '--body', body]
        : ['dns', 'records', 'update', requiredString(records.single, 'id'), '--zone', zone, '--body', body];
      await cf([...dns, '--dry-run']); await cf(dns);
    }
    var domain = jsonObject(await cf(['pages', 'domains', 'get', hostname, '--project-name', projectName]));
    if (domain['status'] != 'active') {
      final retry = ['pages', 'domains', 'validation', 'retry', hostname, '--project-name', projectName];
      await cf([...retry, '--dry-run']); await cf(retry);
      final domainDeadline = DateTime.now().add(const Duration(minutes: 3));
      while (domain['status'] != 'active') {
        if (DateTime.now().isAfter(domainDeadline)) throw StateError('Pages is deployed, but $hostname is still ${domain['status']}');
        await cancellableDelay(const Duration(seconds: 3), cancellation);
        domain = jsonObject(await cf(['pages', 'domains', 'get', hostname, '--project-name', projectName]));
      }
    }
    await File('build/web-deployment.json').writeAsString(jsonEncode({'project': projectName,
      'deployment': deployment['id'], 'url': deployment['url'], 'domain': hostname, 'uses_functions': false}), flush: true);
    stdout.writeln('Deployed static Pages SPA: https://$hostname (${deployment['url']}).');
  } finally {
    cancellation.cancel(); child?.kill(); http.close(force: true);
    for (final signal in signals) { await signal.cancel(); }
  }
}

String _contentType(String path) => switch (path.split('.').last.toLowerCase()) {
  'html' => 'text/html; charset=utf-8', 'js' || 'mjs' => 'text/javascript; charset=utf-8',
  'json' => 'application/json', 'wasm' => 'application/wasm', 'css' => 'text/css; charset=utf-8',
  'svg' => 'image/svg+xml', 'png' => 'image/png', 'jpg' || 'jpeg' => 'image/jpeg',
  'ttf' => 'font/ttf', 'otf' => 'font/otf', 'woff2' => 'font/woff2',
  'wav' => 'audio/wav', 'mp3' => 'audio/mpeg', _ => 'application/octet-stream',
};
