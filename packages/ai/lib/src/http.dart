import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http2/transport.dart' as h2;
import 'package:protocol/protocol.dart';

/// A response owns a stream, never the connection carrying other requests.
class HttpReply extends StreamView<List<int>> {
  HttpReply(super.stream, this.statusCode, this.headers, this.version, {this.reasonPhrase = ''});
  final int statusCode;
  final Map<String, String> headers;
  final String version;
  final String reasonPhrase;
}

/// One instance belongs to the network owner and is shared by both providers.
/// ALPN chooses HTTP/2; an origin choosing HTTP/1.1 uses the existing IO pool.
class HttpConnections {
  HttpConnections({HttpClient? http, this.context, this.connectTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(minutes: 5)}) : _reuseFallback = http != null && HttpOverrides.current == null {
    // The owner supplies a newly created IO client; its factory also serves
    // WebSocket upgrades, which continue to negotiate HTTP/1.1.
    if (_reuseFallback) http!.connectionFactory = _http1Connection;
  }

  final SecurityContext? context;
  final Duration connectTimeout, idleTimeout;
  final _lifetime = CancellationToken();
  final _origins = <String, Future<_Connection?>>{};
  final _connections = <_Connection>{};
  final bool _reuseFallback;
  final _fallback = <String, ({SecureSocket socket, Timer idle})>{};

  Future<ConnectionTask<Socket>> _http1Connection(Uri uri, String? proxyHost, int? proxyPort) async {
    if (proxyHost == null) {
      final prepared = _fallback.remove(uri.origin);
      if (prepared != null) {
        prepared.idle.cancel();
        return ConnectionTask.fromSocket(Future<Socket>.value(prepared.socket), prepared.socket.destroy);
      }
    }
    return uri.scheme == 'https' && proxyHost == null
        ? SecureSocket.startConnect(uri.host, uri.port, context: context, supportedProtocols: ['http/1.1'])
        : Socket.startConnect(proxyHost ?? uri.host, proxyPort ?? uri.port);
  }

  Future<_Connection?> _connect(Uri uri) => _tlsPreflight(() => _dial(uri), _lifetime);

  Future<_Connection?> _dial(Uri uri) async {
    final deadline = TimeoutCancellationToken(connectTimeout);
    final token = _lifetime.merge(deadline);
    ConnectionTask<SecureSocket>? opening;
    SecureSocket? socket;
    _Connection? created;
    var retained = false;
    final hook = CancellationHook(token, () { opening?.cancel(); socket?.destroy(); });
    try {
      opening = await SecureSocket.startConnect(uri.host, uri.port,
        context: context, supportedProtocols: ['h2', 'http/1.1']).then((task) {
          if (token.isCancelled) task.cancel();
          return task;
        }).asCancellable(token);
      socket = await opening.socket.then((value) {
        if (token.isCancelled) value.destroy();
        return value;
      }).asCancellable(token);
      token.throwIfCancelled();
      if (socket.selectedProtocol != 'h2') {
        if (_reuseFallback) {
          final ready = socket;
          _fallback[uri.origin] = (socket: ready, idle: Timer(idleTimeout, () {
            _fallback.remove(uri.origin);
            ready.destroy();
          }));
          retained = true;
        } else {
          socket.destroy();
        }
        return null;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      final connection = _Connection(socket, h2.ClientTransportConnection.viaSocket(socket));
      created = connection;
      _connections.add(connection);
      connection.onClosed = () => _connections.remove(connection);
      connection.transport.onActiveStateChanged = (active) {
        connection.idle?.cancel();
        if (!active) connection.idle = Timer(idleTimeout, connection.close);
      };
      connection.frames = connection.transport.onFrameReceived.listen((_) {
        if (connection.active < (connection.transport.peerMaxConcurrentStreams ?? 100)) connection.notify();
      },
        onDone: connection.close, onError: (Object _) => connection.close());
      await Future.any([
        connection.transport.onInitialPeerSettingsReceived,
        connection.closed.future.then<void>((_) => throw const HttpException('HTTP/2 connection closed')),
      ]).asCancellable(token);
      if (connection.active == 0) connection.idle = Timer(idleTimeout, connection.close);
      retained = true;
      return connection;
    } finally {
      hook.dispose();
      deadline.cancel();
      if (!retained) {
        socket?.destroy();
        created?.close();
        _connections.remove(created);
      }
    }
  }

  Future<_Connection?> _acquire(Uri uri, CancellationToken token) async {
    final origin = uri.origin;
    while (true) {
      token.throwIfCancelled();
      final opening = _origins.putIfAbsent(origin, () {
        final future = _connect(uri);
        unawaited(future.catchError((Object error) {
          _origins.remove(origin);
          return null;
        }));
        return future;
      });
      final connection = await opening.asCancellable(token);
      token.throwIfCancelled();
      if (connection == null) return null;
      if (connection.closed.isCompleted) {
        _origins.remove(origin);
        _connections.remove(connection);
        connection.close();
        continue;
      }
      final limit = connection.transport.peerMaxConcurrentStreams ?? 100;
      if (connection.active >= limit) {
        await connection.changed.future.asCancellable(token);
        continue;
      }
      if (!connection.transport.isOpen) {
        _origins.remove(origin);
        connection.draining = true;
        if (connection.active == 0) connection.close();
        continue;
      }
      connection.idle?.cancel();
      connection.active++;
      return connection;
    }
  }

  Future<HttpReply> send(HttpClient http, String method, Uri uri, {
    required CancellationToken cancellation,
    Map<String, String> headers = const {},
    List<int> body = const [],
  }) async {
    final token = cancellation.merge(_lifetime);
    token.throwIfCancelled();
    // Explicit IO overrides own routing and certificate policy. Do not bypass
    // them with a raw TLS socket (for example a configured HTTPS proxy).
    final connection = uri.scheme == 'https' && HttpOverrides.current == null ? await _acquire(uri, token) : null;
    token.throwIfCancelled();
    if (connection == null) return _http1(http, method, uri, token, headers, body);
    return _http2(connection, method, uri, token, headers, body);
  }

  Future<void> close() async {
    _lifetime.cancel();
    for (final ready in _fallback.values) { ready.idle.cancel(); ready.socket.destroy(); }
    _fallback.clear();
    for (final connection in _connections.toList()) { connection.close(); }
    await Future.wait(_origins.values.map((future) async {
      try { (await future)?.close(); } catch (_) { /* Closing cancels pending dials. */ }
    }));
    _origins.clear();
    _connections.clear();
  }
}

class _Connection {
  _Connection(this.socket, this.transport);
  final SecureSocket socket;
  final h2.ClientTransportConnection transport;
  final closed = Completer<void>();
  Completer<void> changed = Completer<void>();
  StreamSubscription<void>? frames;
  Timer? idle;
  int active = 0;
  bool draining = false;
  void Function()? onClosed;

  void release() {
    active--;
    notify();
    if (draining && active == 0) close();
  }

  void notify() {
    final previous = changed;
    changed = Completer<void>();
    if (!previous.isCompleted) previous.complete();
  }

  void close() {
    if (closed.isCompleted) return;
    closed.complete();
    onClosed?.call();
    idle?.cancel();
    if (!changed.isCompleted) changed.complete();
    socket.destroy();
    unawaited(frames?.cancel());
    unawaited(transport.terminate().catchError((Object _) {}));
  }
}

Future<HttpReply> _http2(_Connection connection, String method, Uri uri,
  CancellationToken token, Map<String, String> headers, List<int> body) async {
  h2.ClientTransportStream? stream;
  StreamSubscription<h2.StreamMessage>? subscription;
  CancellationHook? hook;
  final status = Completer<int>();
  final fields = <String, String>{};
  var settled = false;
  late StreamController<List<int>> incoming;
  Future<void> stop() async {
    if (settled) return;
    settled = true;
    hook?.dispose();
    stream?.terminate();
    connection.release();
    await subscription?.cancel();
    if (!incoming.isClosed) unawaited(incoming.close());
  }
  incoming = StreamController<List<int>>(
    onCancel: stop,
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
  );
  try {
    stream = connection.transport.makeRequest([
      h2.Header.ascii(':method', method), h2.Header.ascii(':scheme', uri.scheme),
      h2.Header.ascii(':authority', uri.hasPort ? '${uri.host}:${uri.port}' : uri.host),
      h2.Header.ascii(':path', '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}'),
      h2.Header.ascii('accept-encoding', 'gzip'),
      for (final entry in headers.entries)
        if (!{'host', 'connection', 'keep-alive', 'transfer-encoding', 'upgrade', 'accept-encoding'}.contains(entry.key.toLowerCase()))
          h2.Header(ascii.encode(entry.key.toLowerCase()), utf8.encode(entry.value),
            neverIndexed: RegExp(r'authorization|cookie|token|api.key', caseSensitive: false).hasMatch(entry.key)),
    ], endStream: body.isEmpty);
    subscription = stream.incomingMessages.listen((message) {
      if (message is h2.HeadersStreamMessage) {
        final values = {for (final header in message.headers) ascii.decode(header.name): utf8.decode(header.value)};
        final code = int.tryParse(values.remove(':status') ?? '');
        if (code != null && code >= 200 && !status.isCompleted) {
          fields.addAll(values);
          status.complete(code);
        }
      } else if (message is h2.DataStreamMessage) {
        incoming.add(message.bytes);
      }
    }, onError: (Object error, StackTrace stack) {
      // Preserve the providers' existing bounded recovery for disconnected IO.
      final failure = error is CancelledException ? error : const HttpException('HTTP/2 stream disconnected');
      if (!status.isCompleted) { status.completeError(failure, stack); }
      else { incoming.addError(failure, stack); }
      unawaited(stop());
    }, onDone: () {
      if (!status.isCompleted) status.completeError(const HttpException('HTTP/2 stream closed before response headers'));
      unawaited(stop());
    });
    hook = CancellationHook(token, () {
      if (!status.isCompleted) { status.completeError(token.exception!); }
      else if (!incoming.isClosed) { incoming.addError(token.exception!); }
      unawaited(stop());
    });
    token.throwIfCancelled();
    if (body.isNotEmpty) stream.sendData(body, endStream: true);
    final code = await status.future.asCancellable(token);
    final bytes = fields['content-encoding'] == 'gzip' ? incoming.stream.transform(gzip.decoder) : incoming.stream;
    return HttpReply(bytes, code, fields, '2');
  } catch (_) {
    await stop();
    token.throwIfCancelled();
    rethrow;
  }
}

Future<HttpReply> _http1(HttpClient http, String method, Uri uri,
  CancellationToken cancellation, Map<String, String> headers, List<int> body) async {
  final request = await _tlsPreflight(() => http.openUrl(method, uri).then((value) {
    if (cancellation.isCancelled) value.abort(cancellation.exception);
    return value;
  }).asCancellable(cancellation), cancellation);
  try {
    cancellation.throwIfCancelled();
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.contentLength = body.length;
    if (body.isNotEmpty) request.add(body);
    final response = await request.close().then((value) {
      if (cancellation.isCancelled) unawaited(value.listen((_) {}).cancel());
      return value;
    }).asCancellable(cancellation,
      onCancel: () => request.abort(cancellation.exception));
    final fields = <String, String>{};
    response.headers.forEach((name, values) => fields[name.toLowerCase()] = values.join(', '));
    final incoming = ownStream(response, cancellation);
    return HttpReply(incoming.stream, response.statusCode, fields, '1.1', reasonPhrase: response.reasonPhrase);
  } catch (_) {
    request.abort();
    cancellation.throwIfCancelled();
    rethrow;
  }
}

// TLS failure here precedes HTTP headers/body, so retrying cannot replay a POST.
Future<T> _tlsPreflight<T>(Future<T> Function() connect, CancellationToken cancellation) async {
  for (var attempt = 0; ; attempt++) {
    cancellation.throwIfCancelled();
    try { return await connect(); }
    on HandshakeException {
      cancellation.throwIfCancelled();
      if (attempt != 0) { rethrow; }
      await cancellableDelay(const Duration(milliseconds: 200), cancellation);
    }
  }
}

Future<HttpReply> httpRequest(HttpClient http, String method, Uri uri, {
  required CancellationToken cancellation,
  HttpConnections? connections,
  Map<String, String> headers = const {},
  List<int> body = const [],
  Duration? headersTimeout,
  bool followRedirects = false,
}) async {
  final deadline = CancellationToken();
  final timer = headersTimeout == null ? null : Timer(headersTimeout,
    () => deadline.cancel(TimeoutException('HTTP response headers timed out')));
  final token = cancellation.merge(deadline);
  try {
    for (var redirects = 0; ; redirects++) {
      token.throwIfCancelled();
      if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
        throw const FormatException('HTTP request requires an HTTP(S) URL without embedded credentials');
      }
      final response = connections == null ? await _http1(http, method, uri, token, headers, body)
          : await connections.send(http, method, uri, cancellation: token, headers: headers, body: body);
      if (!followRedirects || method != 'GET' || !{301, 302, 303, 307, 308}.contains(response.statusCode) ||
          response.headers['location'] == null) { return response; }
      await response.listen((_) {}).cancel();
      if (redirects >= 5) { throw const HttpException('Too many redirects'); }
      final next = uri.resolve(response.headers['location']!);
      if (next.origin != uri.origin) {
        headers = {
          for (final entry in headers.entries)
            if (!RegExp(r'authorization|cookie|token|api.key', caseSensitive: false).hasMatch(entry.key)) entry.key: entry.value,
        };
      }
      uri = next;
    }
  } finally {
    timer?.cancel();
  }
}
