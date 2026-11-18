import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import '../dev_servers.dart';

/// Each browser tab leases a tunnel from its authenticated connection.
/// Concurrent previews of the same origin share a connector.
class BrowserPreviews {
  BrowserPreviews(this._executable);
  final String _executable;
  final _leases = <(String, String), CancellationToken>{};
  final _tunnels = <Uri, _PreviewTunnel>{};
  final _running = <Future<void>>{};

  Future<Json> open(String owner, Json params, CancellationToken cancellation) async {
    final id = requiredString(params, 'lease');
    validateTaskId(id);
    final port = params['port'];
    if (port is! int || port < 1 || port > 65535) throw const FormatException('Expected a valid dev server port');
    final key = (owner, id);
    cancellation.throwIfCancelled();
    if (_leases.containsKey(key)) throw StateError('A browser preview already uses this lease');
    final lease = _leases[key] = CancellationToken();
    final opening = lease.merge(cancellation);
    try {
      final servers = await discoverDevServers(port: port, cancellation: opening);
      opening.throwIfCancelled();
      if (servers.isEmpty) throw RemoteFailure('No local web server is listening on port $port');
      final target = Uri.parse(requiredString(servers.single, 'url'));
      final tunnel = _tunnels.putIfAbsent(target, () => _start(target));
      tunnel._users++;
      CancellationHook(lease, () {
        if (--tunnel._users == 0) {
          if (identical(_tunnels[target], tunnel)) _tunnels.remove(target);
          tunnel.stop();
        }
      });
      final origin = await tunnel.ready.asCancellable(opening);
      opening.throwIfCancelled();
      return {'origin': origin.toString()};
    } catch (_) {
      release(owner, id);
      rethrow;
    }
  }

  _PreviewTunnel _start(Uri target) {
    final tunnel = _PreviewTunnel(_executable, target);
    final done = tunnel.done;
    _running.add(done);
    unawaited(done.whenComplete(() {
      if (identical(_tunnels[target], tunnel)) _tunnels.remove(target);
      _running.remove(done);
    }));
    return tunnel;
  }

  void release(String owner, String id) => _leases.remove((owner, id))?.cancel();

  void detach(String owner) {
    for (final key in _leases.keys.where((key) => key.$1 == owner).toList()) {
      _leases.remove(key)?.cancel();
    }
  }

  Future<void> close() async {
    for (final lease in _leases.values) { lease.cancel(); }
    _leases.clear();
    await Future.wait(_running.toList());
  }
}

class _PreviewTunnel {
  _PreviewTunnel(String executable, Uri target) { done = _run(executable, target); }

  final _lifetime = CancellationToken();
  final _ready = Completer<Uri>();
  int _users = 0;
  late final Future<void> done;
  Future<Uri> get ready => _ready.future;
  void stop() => _lifetime.cancel();

  Future<void> _run(String executable, Uri target) async {
    try {
      // A newly registered Quick Tunnel can have an unpublished hostname.
      for (var attempt = 0; attempt < 3 && !_lifetime.isCancelled && !_ready.isCompleted; attempt++) {
        await _connect(executable, target);
      }
      if (!_ready.isCompleted) {
        _ready.completeError(const RemoteFailure('Cloudflare did not make the dev server reachable. Try again.'));
      }
    } catch (_) {
      if (!_ready.isCompleted) _ready.completeError(const RemoteFailure('Could not start the Cloudflare preview connector'));
    }
  }

  Future<void> _connect(String executable, Uri target) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 11));
    final opening = _lifetime.merge(deadline);
    Future<void>? verification;
    try {
      final child = await Process.start(executable, ['tunnel', '--config', '/dev/null', '--no-autoupdate',
        '--metrics', '127.0.0.1:0', '--loglevel', 'info', '--url', target.toString(),
        '--http-host-header', target.authority, '--protocol', 'auto']);
      void kill() => child.kill(ProcessSignal.sigkill);
      final hook = CancellationHook(_lifetime, kill);
      final timeout = CancellationHook(deadline, kill);
      if (opening.isCancelled) kill();
      Uri? origin;
      var connected = false;
      final address = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com\b');
      void line(String value) {
        if (_ready.isCompleted || verification != null || opening.isCancelled) return;
        if (address.firstMatch(value) case final match?) origin = Uri.parse(match[0]!);
        if (value.contains('Registered tunnel connection')) connected = true;
        if (origin case final url? when connected) {
          verification = _waitForPublicPreview(url, opening).then((_) {
            if (opening.isCancelled) return;
            timeout.dispose();
            deadline.cancel();
            _ready.complete(url);
          }, onError: (Object error) { if (!opening.isCancelled) kill(); });
        }
      }
      Future<void> read(Stream<List<int>> output) => const Utf8Decoder(allowMalformed: true)
        .bind(output).transform(const LineSplitter()).forEach(line);
      try {
        await Future.wait([child.exitCode, read(child.stdout), read(child.stderr)]);
      } finally { hook.dispose(); timeout.dispose(); }
    } finally {
      deadline.cancel();
      await verification;
    }
  }
}

Future<void> _waitForPublicPreview(Uri uri, CancellationToken cancellation) async {
  await cancellableDelay(const Duration(seconds: 1), cancellation);
  while (true) {
    cancellation.throwIfCancelled();
    final deadline = TimeoutCancellationToken(const Duration(seconds: 3));
    final token = cancellation.merge(deadline);
    final http = HttpClient()..findProxy = (_) => 'DIRECT';
    final hook = CancellationHook(token, () => http.close(force: true));
    try {
      final request = await http.getUrl(uri).asCancellable(token);
      request.followRedirects = false;
      final reply = await request.close().asCancellable(token);
      if (!{502, 503, 504, 530}.contains(reply.statusCode)) return;
    } catch (_) { cancellation.throwIfCancelled(); }
    finally { hook.dispose(); deadline.cancel(); http.close(force: true); }
    await cancellableDelay(const Duration(milliseconds: 500), cancellation);
  }
}
