import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'src/web_access.dart';

/// The public gateway keeps browser authentication at the HTTP boundary and
/// forwards only authenticated connections to the private server socket.
class WebGateway {
  WebGateway._(this.http, this.access, this.socketPath);
  final HttpServer http;
  final WebAccess access;
  final String socketPath;
  final _connections = <({WebSocket browser, WebSocket server})>{};
  final _lifetime = CancellationToken();
  final _pending = <Future<void>>{};
  Future<void>? _closing;

  static Future<WebGateway> start({required String socketPath,
    required String publicUrl, required String ownerKeyFile, Set<String> allowedOrigins = const {}, int port = 8787}) async {
    final uri = Uri.parse(publicUrl);
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment || uri.path != '' && uri.path != '/') {
      throw ArgumentError('The public URL must be an HTTPS origin');
    }
    final access = await WebAccess.open(publicUrl, ownerKeyFile, allowedOrigins: allowedOrigins);
    try {
      final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      final gateway = WebGateway._(listener, access, socketPath);
      listener.listen((request) {
        final operation = gateway._accept(request).catchError((Object _) {
          unawaited(request.response.close().catchError((Object _) {}));
        });
        gateway._pending.add(operation);
        unawaited(operation.whenComplete(() => gateway._pending.remove(operation)));
      });
      return gateway;
    } catch (_) { access.close(); rethrow; }
  }

  Future<void> _accept(HttpRequest request) async {
    request.response.headers.set('X-Happen-Gateway', '1');
    if (_lifetime.isCancelled) { request.response.statusCode = 503; await request.response.close(); return; }
    final origin = request.headers.value('origin');
    if (origin != null && !access.permitsOrigin(request)) {
      stderr.writeln('Rejected browser origin ${clippedText(origin, 160)} for ${request.method} ${request.uri.path}; cf-ray=${request.headers.value('cf-ray') ?? '-'}');
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    if (request.uri.path != '/ws') {
      await access.handle(request);
      return;
    }
    if (!access.permitsOrigin(request)) {
      request.response.statusCode = 401;
      request.response.headers.set('Cache-Control', 'no-store');
      await request.response.close();
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    final browser = await WebSocketTransformer.upgrade(request, compression: CompressionOptions.compressionOff);
    final messages = StreamIterator<dynamic>(browser);
    final authentication = TimeoutCancellationToken(const Duration(seconds: 5));
    var valid = false;
    try {
      if (await messages.moveNext().asCancellable(authentication.merge(_lifetime))) {
        final frame = messages.current;
        if (frame is String && frame.length <= 4096) {
          final value = jsonObject(jsonDecode(frame));
          valid = value['type'] == 'authenticate' && value['token'] is String && access.permitsToken(value['token'] as String, origin!);
        }
      }
    } on FormatException { /* No protocol authority before authentication. */ }
    on CancelledException { /* Bounded authentication handshake. */ }
    finally { authentication.cancel(); }
    if (!valid) { await browser.close(1008, 'Owner authentication required'); await messages.cancel(); return; }
    final http = HttpClient();
    http.findProxy = (_) => 'DIRECT';
    http.connectionFactory = (_, _, _) => Socket.startConnect(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    final deadline = TimeoutCancellationToken(const Duration(seconds: 10));
    final hook = CancellationHook(_lifetime.merge(deadline), () => http.close(force: true));
    WebSocket? upstream;
    try {
      upstream = await WebSocket.connect('ws://localhost/ws', customClient: http,
        compression: CompressionOptions.compressionOff).asCancellable(_lifetime.merge(deadline));
    } catch (_) {
      await browser.close(1013, 'The server is unavailable');
      await messages.cancel();
      return;
    } finally { hook.dispose(); deadline.cancel(); http.close(); }
    browser.add('{"type":"authenticated"}');
    final connection = (browser: browser, server: upstream);
    _connections.add(connection);
    browser.pingInterval = const Duration(seconds: 30);
    upstream.pingInterval = const Duration(seconds: 30);
    Future<void> forward(WebSocket from, WebSocket to) async {
      try {
        await for (final message in from) {
          if (to.readyState != WebSocket.open) break;
          to.add(message);
        }
      } on WebSocketException { /* Peer closed. */ }
      on SocketException { /* Tunnel and server recover through a fresh connection. */ }
      finally { await to.close(); }
    }
    Future<void> browserToServer() async {
      try {
        while (await messages.moveNext()) {
          if (upstream!.readyState != WebSocket.open) break;
          upstream.add(messages.current);
        }
      } on WebSocketException { /* Peer closed. */ }
      on SocketException { /* Peer disconnected. */ }
      finally { await upstream!.close(); await messages.cancel(); }
    }
    try { await Future.wait([browserToServer(), forward(upstream, browser)]); }
    finally { _connections.remove(connection); }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _lifetime.cancel();
    access.close();
    await http.close(force: true);
    await Future.wait([for (final connection in _connections.toList()) ...[
      connection.browser.close(), connection.server.close(),
    ]]);
    await Future.wait(_pending.toList());
  }
}
