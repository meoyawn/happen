part of '../server.dart';

/// The browser runs beside the client, including when its server is remote.
/// A worker owns the listener; only callback data crosses the existing RPC.
Future<Json> _mcpClientLogin(AgentClient client, String server, String loginId, {
  String? cwd, required CancellationToken cancellation,
}) async {
  final lifetime = TimeoutCancellationToken(const Duration(minutes: 6));
  final token = cancellation.merge(lifetime);
  final ready = Completer<int>(), forwarding = <Future<void>>{};

  Future<void> forward(Json event) async {
    final reply = event['reply'] as SendPort;
    var accepted = false;
    try {
      accepted = await client._request('mcp.auth.callback', {
        'server': server, 'login_id': loginId, 'cwd': ?cwd, 'callback_url': event['callback_url'],
      }, cancellation: token, timeout: const Duration(seconds: 10)) == true;
    } catch (_) { /* Invalid callbacks leave the intended sign-in available. */ }
    finally { reply.send(accepted); }
  }

  final listening = runIsolateEffect<void>(_mcpCallbackListener, {}, cancellation: token, onEvent: (event) {
    if (token.isCancelled) return;
    if (event['port'] case final int port) {
      if (!ready.isCompleted) ready.complete(port);
    } else {
      final pending = forward(event);
      forwarding.add(pending);
      unawaited(pending.whenComplete(() => forwarding.remove(pending)));
    }
  });
  final stopped = listening.then<Never>((_) => throw StateError('MCP callback listener stopped'));
  unawaited(stopped.then<void>((_) {}, onError: (Object _) {}));
  try {
    final port = await Future.any<int>([ready.future, stopped]).asCancellable(token);
    return jsonObject(await Future.any<Object?>([
      client._request('mcp.auth.login', {'server': server, 'login_id': loginId, 'cwd': ?cwd, 'callback_port': port},
        cancellation: token, timeout: const Duration(minutes: 6)),
      stopped,
    ]));
  } finally {
    lifetime.cancel();
    try { await listening; } catch (_) { /* The sign-in owns the reported failure. */ }
    await Future.wait(forwarding.toList());
  }
}

Future<void> _mcpCallbackListener(Json params, CancellationToken cancellation, void Function(Json) notify) async {
  final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final ended = CancellableCompleter<void>(cancellation), pending = <Future<void>>{};
  // Own cancellation even if it arrives while binding the listener.
  unawaited(ended.future.then<void>((_) {}, onError: (Object _) {}));
  StreamSubscription<HttpRequest>? subscription;

  Future<void> respond(HttpRequest request) async {
    var status = 404;
    try {
      if (request.method == 'GET' && request.uri.path.startsWith('/callback')) {
        status = 400;
        final callback = Uri(scheme: 'http', host: '127.0.0.1', port: listener.port,
          path: request.uri.path, query: request.uri.hasQuery ? request.uri.query : null).toString();
        if (utf8.encode(callback).length <= 65536) {
          final reply = ReceivePort();
          try {
            notify({'callback_url': callback, 'reply': reply.sendPort});
            if (await reply.first.asCancellable(cancellation) == true) status = 200;
          } finally { reply.close(); }
        }
      }
    } catch (_) { status = 400; }
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.html;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('Referrer-Policy', 'no-referrer');
      request.response.write(status == 200
        ? '<!doctype html><title>Happen</title><p>Authorization received. You can return to Happen.</p>'
        : '<!doctype html><title>Happen</title><p>Sign-in failed. Return to Happen and try again.</p>');
      await request.response.close().timeout(const Duration(seconds: 2));
    } on HttpException { /* The browser may close the tab before the response. */
    } on SocketException { /* Sign-in completion belongs to the server. */
    } on TimeoutException { /* Listener cleanup closes an unresponsive browser. */ }
  }

  try {
    cancellation.throwIfCancelled();
    subscription = listener.listen((request) {
      final response = respond(request);
      pending.add(response);
      unawaited(response.whenComplete(() => pending.remove(response)));
    }, onError: (Object error, StackTrace stack) {
      if (!ended.isCompleted) ended.completeError(error, stack);
    });
    notify({'port': listener.port});
    await ended.future;
  } finally {
    await subscription?.cancel();
    await Future.wait(pending.toList());
    await listener.close(force: true);
  }
}
