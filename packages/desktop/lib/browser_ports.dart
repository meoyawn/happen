import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';

/// Ported from t3code's preview/PortScanner: machine-readable listener records,
/// loopback/wildcard filtering, deduplication, bounded HTML/redirect probes.
/// Process and HTTP resources are created and released in the effect isolate.
Future<List<Json>> discoverBrowserPorts({required CancellationToken cancellation}) =>
  runIsolateEffect(_discover, {}, cancellation: cancellation, timeout: const Duration(seconds: 15));

Future<List<Json>> _discover(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
  final token = cancellation.merge(deadline);
  String output;
  try {
    token.throwIfCancelled();
    final process = await Process.start('lsof', ['-iTCP', '-sTCP:LISTEN', '-P', '-n', '-Fpcn']);
    final hook = CancellationHook(token, () => process.kill(ProcessSignal.sigkill));
    try {
      final results = await Future.wait<Object>([
        process.exitCode,
        utf8.decoder.bind(process.stdout).join(),
        utf8.decoder.bind(process.stderr).join(),
      ]).asCancellable(token);
      output = results[1] as String;
      if (output.length > 1024 * 1024) throw StateError('Too many listening ports.');
      if (results.first != 0 && !(results.first == 1 && output.isEmpty)) {
        throw StateError('Could not discover local servers.');
      }
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      hook.dispose();
    }
  } finally { deadline.cancel(); }
  cancellation.throwIfCancelled();
  final listeners = <String, Json>{};
  int? processId;
  String? name;
  for (final line in const LineSplitter().convert(output)) {
    if (line.isEmpty) continue;
    final value = line.substring(1);
    switch (line[0]) {
      case 'p': processId = int.tryParse(value); name = null;
      case 'c': name = value;
      case 'n':
        if (processId == pid) continue;
        final match = RegExp(r'^(.*):(\d+)$').firstMatch(value);
        if (match == null) continue;
        final port = int.tryParse(match[2]!);
        var host = match[1]!.replaceAll(RegExp(r'^\[|\]$'), '');
        if (!{'*', '0.0.0.0', '::', 'localhost'}.contains(host) &&
            InternetAddress.tryParse(host)?.isLoopback != true) continue;
        if (port == null || port < 1 || port > 65535) continue;
        if (host == '*' || host == '0.0.0.0' || host == 'localhost') host = '127.0.0.1';
        if (host == '::') host = '::1';
        final url = Uri(scheme: 'http', host: host, port: port).toString();
        listeners.putIfAbsent(url, () => {'url': url, 'port': port, 'processName': name, 'pid': processId});
    }
  }
  final candidates = listeners.values.toList(), servers = <int, Json>{};
  var next = 0;
  await Future.wait(List.generate(candidates.length.clamp(0, 16), (_) async {
    while (next < candidates.length) {
      cancellation.throwIfCancelled();
      final candidate = candidates[next++];
      if (await _webServer(Uri.parse(candidate['url'] as String), cancellation)) {
        servers.putIfAbsent(candidate['port'] as int, () => candidate);
      }
    }
  }));
  return servers.values.toList()..sort((a, b) => (a['port'] as int).compareTo(b['port'] as int));
}

Future<bool> _webServer(Uri uri, CancellationToken cancellation) async {
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

sealed class _PortsState {
  const _PortsState(this.servers);
  final List<Json> servers;
}
final class _PortsIdle extends _PortsState { const _PortsIdle() : super(const []); }
final class _PortsLoading extends _PortsState { const _PortsLoading(super.servers); }
final class _PortsReady extends _PortsState { const _PortsReady(super.servers); }
final class _PortsFailed extends _PortsState { const _PortsFailed(super.servers); }

_PortsState _transition(_PortsState current, _PortsState next) => switch ((current, next)) {
  (_PortsIdle() || _PortsReady() || _PortsFailed(), _PortsLoading()) => next,
  (_PortsLoading(), _PortsReady() || _PortsFailed()) => next,
  _ => throw StateError('Invalid browser port discovery transition'),
};

class BrowserPorts extends StatefulWidget {
  const BrowserPorts({super.key, required this.active, required this.onOpen});
  final bool active;
  final ValueChanged<Uri> onOpen;
  @override
  State<BrowserPorts> createState() => _BrowserPortsState();
}

class _BrowserPortsState extends State<BrowserPorts> {
  _PortsState _state = const _PortsIdle();
  CancellationToken? _operation;
  Timer? _poll;

  @override
  void initState() { super.initState(); if (widget.active) unawaited(_refresh()); }
  @override
  void didUpdateWidget(BrowserPorts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) { _poll?.cancel(); _operation?.cancel(); }
    else if (!oldWidget.active) unawaited(_refresh());
  }
  @override
  void dispose() { _poll?.cancel(); _operation?.cancel(); super.dispose(); }

  Future<void> _refresh() async {
    _poll?.cancel();
    _operation?.cancel();
    final operation = _operation = CancellationToken();
    if (_state is _PortsLoading) _state = _transition(_state, _PortsReady(_state.servers));
    setState(() => _state = _transition(_state, _PortsLoading(_state.servers)));
    try {
      final servers = await discoverBrowserPorts(cancellation: operation);
      if (mounted && !operation.isCancelled) setState(() => _state = _transition(_state, _PortsReady(servers)));
    } on CancelledException { /* Hidden and closed tabs stop discovery. */ }
    catch (_) {
      if (mounted && !operation.isCancelled) setState(() => _state = _transition(_state, _PortsFailed(_state.servers)));
    } finally {
      if (mounted && widget.active && !operation.isCancelled) {
        _poll = Timer(const Duration(seconds: 3), () => unawaited(_refresh()));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460),
    child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(28), children: [
      const Icon(Icons.language_rounded, size: 28, color: desktopTertiary),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Text('Local dev servers', style: TextStyle(fontSize: 14, color: desktopSecondary)),
        const SizedBox(width: 8),
        SizedBox.square(dimension: 24, child: _state is _PortsLoading && _state.servers.isEmpty
          ? const Icon(Icons.hourglass_empty_rounded, size: 16, color: desktopTertiary)
          : IconButton(tooltip: 'Refresh local servers', padding: EdgeInsets.zero,
              onPressed: widget.active ? () => unawaited(_refresh()) : null,
              icon: const Icon(Icons.refresh_rounded, size: 16, color: desktopSecondary))),
      ]),
      const SizedBox(height: 8),
      if (_state is _PortsFailed)
        const Text('Could not discover local servers. Try refreshing.', textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: desktopTertiary))
      else if (_state.servers.isEmpty && _state is! _PortsLoading)
        const Text('No web servers found. Start a dev server or enter a URL above.', textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: desktopTertiary)),
      for (final server in _state.servers)
        ListTile(key: ValueKey('browser-port:${server['port']}'), dense: true,
          leading: const Icon(Icons.dns_outlined, size: 18, color: desktopSecondary),
          title: Text(server['url'] as String, style: const TextStyle(fontSize: 12, color: desktopForeground)),
          subtitle: server['processName'] is String ? Text(server['processName'] as String,
            style: const TextStyle(fontSize: 11, color: desktopTertiary)) : null,
          trailing: const Icon(Icons.arrow_forward_rounded, size: 16, color: desktopTertiary),
          onTap: () => widget.onOpen(Uri.parse(server['url'] as String))),
    ])));
}
