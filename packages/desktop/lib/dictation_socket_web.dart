import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;

class BrowserDictationSocket {
  BrowserDictationSocket._(this._socket, this._cancellation, this._live, this._onTranscript, this._onError) {
    _ready.future.ignore();
    _finished.future.ignore();
  }

  final web.WebSocket _socket;
  final CancellationToken _cancellation;
  final bool _live;
  final void Function(String)? _onTranscript;
  final void Function()? _onError;
  final _ready = Completer<void>();
  final _finished = Completer<String>();
  final _subscriptions = <StreamSubscription<web.Event>>[];
  CancellationHook? _hook;
  Object? _failure;
  bool _closed = false;

  static const _disconnected = RemoteFailure('Check your connection and try again');

  static Future<BrowserDictationSocket> connect(Uri uri, String authentication, String scope, {required bool live,
    required CancellationToken cancellation, void Function(String)? onTranscript, void Function()? onError}) async {
    cancellation.throwIfCancelled();
    final socket = web.WebSocket(uri.toString());
    final connection = BrowserDictationSocket._(socket, cancellation, live, onTranscript, onError);
    connection._subscriptions.addAll([
      socket.onOpen.listen((_) => socket.send(authentication.toJS)),
      socket.onError.listen((_) => connection._fail(_disconnected)),
      socket.onClose.listen((event) {
        if (connection._finished.isCompleted) return;
        connection._fail(switch (event.code) {
          1008 => const RemoteFailure('Sign in with your owner key'),
          1013 => const RemoteFailure('The server is unavailable. Try again shortly.'),
          _ => _disconnected,
        });
      }),
      socket.onMessage.listen((event) => connection._receive(event, scope)),
    ]);
    connection._hook = CancellationHook(cancellation, connection.close);
    final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
    try {
      await connection._ready.future.asCancellable(cancellation.merge(deadline));
      return connection;
    } catch (_) {
      connection.close();
      rethrow;
    } finally { deadline.cancel(); }
  }

  void _receive(web.MessageEvent event, String scope) {
    try {
      final message = jsonObject(jsonDecode((event.data as JSString).toDart));
      switch (message) {
        case {'type': 'authenticated'}:
          _socket.send(jsonEncode({'type': 'start', 'live': _live, 'account_scope': scope}).toJS);
        case {'type': 'ready'}:
          _ready.complete();
        case {'type': 'transcript', 'text': final String text}:
          _onTranscript?.call(text);
        case {'type': 'finished', 'text': final String text}:
          _finished.complete(text);
        case {'type': 'error', 'message': final String message}:
          _fail(RemoteFailure(message));
        default:
          _fail(_disconnected);
      }
    } catch (_) { _fail(_disconnected); }
  }

  void append(Uint8List pcm) {
    if (_closed) return;
    if (_socket.readyState != 1 || _socket.bufferedAmount > 1024 * 1024) {
      _fail(_disconnected);
      return;
    }
    _socket.send(pcm.toJS);
  }

  Future<void> waitForCapacity() async {
    while (!_closed && _socket.bufferedAmount > 512 * 1024) {
      await cancellableDelay(const Duration(milliseconds: 20), _cancellation);
    }
    _checkOpen();
  }

  Future<String> finish() async {
    _checkOpen();
    _socket.send('finish'.toJS);
    final deadline = TimeoutCancellationToken(_live ? const Duration(seconds: 25) : const Duration(seconds: 90));
    try { return await _finished.future.asCancellable(_cancellation.merge(deadline)); }
    finally { deadline.cancel(); }
  }

  void _checkOpen() {
    _cancellation.throwIfCancelled();
    if (_closed || _socket.readyState != 1) throw _failure ?? _disconnected;
  }

  void _fail(Object failure) {
    if (_closed) return;
    _failure = failure;
    close();
    _onError?.call();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final failure = _cancellation.exception ?? _failure ?? _disconnected;
    if (!_ready.isCompleted) _ready.completeError(failure);
    if (!_finished.isCompleted) _finished.completeError(failure);
    _hook?.dispose();
    for (final subscription in _subscriptions) { unawaited(subscription.cancel()); }
    _socket.close();
  }
}
