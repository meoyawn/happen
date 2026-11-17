import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;

/// One shared browser worker owns SQLite across all windows of this origin.
class DesktopDatabase {
  DesktopDatabase(this.worker) {
    _messages = web.EventStreamProviders.messageEvent.forTarget(worker.port).listen((event) {
      final message = jsonObject(jsonDecode((event.data as JSString).toDart));
      final pending = _pending.remove(message['id']);
      if (message['error'] case final String error) { pending?.completeError(StateError(error)); }
      else { pending?.complete(message['result']); }
    });
    _errors = web.EventStreamProviders.errorEvent.forTarget(worker).listen((_) {
      for (final pending in _pending.values) { pending.completeError(StateError('Browser database worker failed')); }
      _pending.clear();
    });
    worker.port.start();
  }
  final web.SharedWorker worker;
  late final StreamSubscription<web.MessageEvent> _messages;
  late final StreamSubscription<web.Event> _errors;
  final _pending = <int, Completer<Object?>>{};
  final _lifetime = CancellationToken();
  int _next = 0;
  bool _closed = false;

  Future<Object?> request(String method, Json params, CancellationToken? cancellation) async {
    if (_closed) throw StateError('Browser database is closed');
    cancellation?.throwIfCancelled();
    final id = ++_next;
    final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
    final token = cancellation == null ? deadline.merge(_lifetime) : cancellation.merge(deadline).merge(_lifetime);
    final pending = CancellableCompleter<Object?>(token, onCancel: () {
      _pending.remove(id);
      worker.port.postMessage(jsonEncode({'method': 'cancel', 'id': id}).toJS);
    });
    _pending[id] = pending;
    worker.port.postMessage(jsonEncode({'id': id, 'method': method, 'params': params}).toJS);
    try { return await pending.future; }
    finally { _pending.remove(id); deadline.cancel(); }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true; _lifetime.cancel();
    await _messages.cancel(); await _errors.cancel();
    worker.port.close();
  }
}

Future<DesktopDatabase> openDesktopDatabase(String directory, {CancellationToken? cancellation}) async {
  cancellation?.throwIfCancelled();
  final owner = DesktopDatabase(web.SharedWorker('/database_worker.dart.js'.toJS, web.WorkerOptions(name: 'happen-sqlite-v1')));
  try { await owner.request('open', {}, cancellation); return owner; }
  catch (_) { await owner.close(); rethrow; }
}

Future<Object?> desktopDatabaseRequest(DesktopDatabase database, String method, Json params,
  {CancellationToken? cancellation}) => database.request(method, params, cancellation);
