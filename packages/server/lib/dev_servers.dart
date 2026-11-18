import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

/// Scan in an effect isolate so desktop discovery leaves the UI isolate free.
Future<List<Json>> discoverDevServers({int? port, required CancellationToken cancellation}) =>
  runIsolateEffect(_discover, {'port': ?port}, cancellation: cancellation, timeout: const Duration(seconds: 15));

typedef _Listener = ({String address, int? processId, String? processName});

Future<List<Json>> _discover(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final output = await _readListeners(cancellation);
  final listeners = <Uri, _Listener>{};
  for (final listener in Platform.isLinux ? _linuxListeners(output) : _lsofListeners(output)) {
    if (listener.processId == pid) continue;
    final separator = listener.address.lastIndexOf(':');
    if (separator < 0) continue;
    final port = int.tryParse(listener.address.substring(separator + 1));
    if (port == null || port < 1 || port > 65535 || params['port'] != null && port != params['port']) continue;
    final host = listener.address.substring(0, separator).replaceAll(RegExp(r'^\[|\]$'), '').split('%').first;
    final targets = switch (host) {
      '*' => ['127.0.0.1', '::1'],
      '0.0.0.0' || 'localhost' => ['127.0.0.1'],
      '::' => ['::1'],
      _ when InternetAddress.tryParse(host)?.isLoopback == true => [host],
      _ => const <String>[],
    };
    for (final target in targets) {
      final url = Uri(scheme: 'http', host: target, port: port);
      listeners.putIfAbsent(url, () => listener);
    }
  }
  final candidates = listeners.keys.toList(), reachable = <Uri>{};
  var next = 0;
  await Future.wait(List.generate(candidates.length.clamp(0, 16), (_) async {
    while (next < candidates.length) {
      cancellation.throwIfCancelled();
      final url = candidates[next++];
      if (await _servesHtml(url, cancellation)) reachable.add(url);
    }
  }));
  final servers = <int, Json>{};
  for (final MapEntry(key: url, value: listener) in listeners.entries) {
    if (reachable.contains(url)) {
      servers.putIfAbsent(url.port, () => {'url': url.toString(), 'port': url.port,
        'processName': listener.processName, 'pid': listener.processId});
    }
  }
  return servers.values.toList()..sort((a, b) => (a['port'] as int).compareTo(b['port'] as int));
}

Future<String> _readListeners(CancellationToken cancellation) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
  final token = cancellation.merge(deadline);
  try {
    token.throwIfCancelled();
    final process = Platform.isLinux
      ? await Process.start('ss', ['-H', '-ltnp'])
      : await Process.start('lsof', ['-iTCP', '-sTCP:LISTEN', '-P', '-n', '-Fpcn']);
    final hook = CancellationHook(token, () => process.kill(ProcessSignal.sigkill));
    try {
      final results = await Future.wait<Object>([
        process.exitCode,
        const Utf8Decoder(allowMalformed: true).bind(process.stdout).join(),
        process.stderr.drain<void>().then((_) => ''),
      ]).asCancellable(token);
      final output = results[1] as String;
      if (output.length > 1024 * 1024) throw StateError('Too many listening ports.');
      if (results.first != 0 && !(results.first == 1 && output.isEmpty && !Platform.isLinux)) {
        throw StateError('Could not discover local servers.');
      }
      return output;
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      hook.dispose();
    }
  } finally { deadline.cancel(); }
}

Iterable<_Listener> _lsofListeners(String output) sync* {
  int? processId;
  String? processName;
  for (final line in const LineSplitter().convert(output)) {
    if (line.isEmpty) continue;
    final value = line.substring(1);
    switch (line[0]) {
      case 'p': processId = int.tryParse(value); processName = null;
      case 'c': processName = value;
      case 'n': yield (address: value, processId: processId, processName: processName);
    }
  }
}

Iterable<_Listener> _linuxListeners(String output) sync* {
  final process = RegExp(r'\("([^"]+)",pid=(\d+),');
  for (final line in const LineSplitter().convert(output)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    // ss exposes process details for sockets owned by the server's user.
    if (fields.length < 6 || fields.first != 'LISTEN') continue;
    for (final match in process.allMatches(line)) {
      yield (address: fields[3], processId: int.tryParse(match[2]!), processName: match[1]);
    }
  }
}

Future<bool> _servesHtml(Uri uri, CancellationToken cancellation) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 1));
  final token = cancellation.merge(deadline);
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  final hook = CancellationHook(token, () => client.close(force: true));
  try {
    final request = await client.getUrl(uri).asCancellable(token);
    request.followRedirects = false;
    final response = await request.close().asCancellable(token);
    final redirect = {301, 302, 303, 307, 308}.contains(response.statusCode) &&
      response.headers.value(HttpHeaders.locationHeader)?.trim().isNotEmpty == true;
    final type = response.headers.contentType?.mimeType.toLowerCase();
    return redirect || response.statusCode >= 200 && response.statusCode < 300 &&
      !{204, 205}.contains(response.statusCode) && {'text/html', 'application/xhtml+xml'}.contains(type);
  } catch (_) {
    cancellation.throwIfCancelled();
    return false;
  } finally { hook.dispose(); deadline.cancel(); client.close(force: true); }
}
