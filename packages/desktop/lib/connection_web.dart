import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';
import 'package:web/web.dart' as web;

import 'browser_files_web.dart';

sealed class _ConnectionState { const _ConnectionState(); }
final class _Idle extends _ConnectionState { const _Idle(); }
final class _Connecting extends _ConnectionState { const _Connecting(); }
final class _Connected extends _ConnectionState { const _Connected(this.socket); final web.WebSocket socket; }
final class _Retrying extends _ConnectionState { const _Retrying(); }
final class _Closed extends _ConnectionState { const _Closed(); }

_ConnectionState _transition(_ConnectionState current, _ConnectionState next) => switch ((current, next)) {
  (_Idle() || _Retrying(), _Connecting()) => next,
  (_Connecting(), _Connected() || _Retrying()) => next,
  (_Connected(), _Retrying()) => next,
  (_, _Closed()) when current is! _Closed => next,
  _ => throw StateError('Invalid browser connection transition'),
};

Uri get gatewayUri {
  const configured = String.fromEnvironment('HAPPEN_SERVER_URL');
  return (configured.isEmpty ? Uri.base : Uri.parse(configured)).replace(path: '/', query: '').removeFragment();
}
final _sessions = <String, String>{};
Uri serverSocketUri([Uri? server]) {
  final origin = server ?? gatewayUri;
  return Uri(scheme: origin.scheme == 'https' ? 'wss' : 'ws', host: origin.host,
    port: origin.hasPort ? origin.port : null, path: '/ws');
}

Future<Json> gatewayRequest(String path, {Uri? server, String method = 'GET', Json? body, required CancellationToken cancellation}) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
  final token = cancellation.merge(deadline);
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      token.throwIfCancelled();
      final abort = web.AbortController();
      final requestDeadline = TimeoutCancellationToken(const Duration(seconds: 8));
      final hook = CancellationHook(token.merge(requestDeadline), () => abort.abort());
      var retry = false;
      try {
        web.Response response;
        try {
          response = await web.window.fetch((server ?? gatewayUri).resolve(path).toString().toJS, web.RequestInit(
            method: method, credentials: 'include', signal: abort.signal,
            headers: (body == null ? <String, String>{} : {'Content-Type': 'application/json'}).jsify()! as JSObject,
            body: body == null ? null : jsonEncode(body).toJS,
          )).toDart;
        } catch (_) {
          token.throwIfCancelled();
          if (attempt == 2) throw const RemoteFailure('Could not reach the server. Check its tunnel and try again.', code: 'unreachable');
          retry = true;
          continue;
        }
        if ({502, 503, 504}.contains(response.status) && attempt < 2) { retry = true; continue; }
        if (response.status == 401) throw const RemoteFailure('Sign in with your owner key', code: 'unauthorized');
        if (!response.ok) throw RemoteFailure(response.status == 429 ? 'Too many sign-in attempts. Try again in ten minutes.'
          : 'The gateway could not complete the request (${response.status})');
        if (response.status == 204) return {};
        return jsonObject(jsonDecode((await response.text().toDart).toDart));
      } finally {
        hook.dispose(); requestDeadline.cancel();
        if (retry) await cancellableDelay(Duration(seconds: attempt + 1), token);
      }
    }
    throw const RemoteFailure('The server is unavailable. Try again shortly.', code: 'unreachable');
  } finally { deadline.cancel(); }
}

Future<void> signInServer(Uri server, String key, CancellationToken cancellation) async {
  final result = await gatewayRequest('/auth/login', server: server, method: 'POST', body: {'key': key}, cancellation: cancellation);
  _sessions[server.origin] = requiredString(result, 'token');
}

Future<void> restoreServerSignIn(Uri server, CancellationToken cancellation) async {
  if (_sessions.containsKey(server.origin)) return;
  final result = await gatewayRequest('/auth/session', server: server, cancellation: cancellation);
  _sessions[server.origin] = requiredString(result, 'token');
}

Future<void> signOutServers(CancellationToken cancellation) async {
  final sessions = Map.of(_sessions);
  _sessions.clear();
  await Future.wait([for (final entry in sessions.entries) (() async {
    try {
      await gatewayRequest('/auth/logout', server: Uri.parse(entry.key), method: 'POST', body: {'token': entry.value}, cancellation: cancellation);
    } catch (_) { /* Closing the client also releases all live connections. */ }
  })()]);
}

class AgentClient {
  AgentClient._(this.uri);
  final Uri uri;
  _ConnectionState _state = const _Idle();
  final _lifetime = CancellationToken();
  final events = StreamController<Json>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  final _subscriptions = <StreamSubscription<web.Event>>[];
  final _ready = Completer<void>();
  Future<void>? _maintaining, _closing;
  Completer<void>? _dropped;
  TraceStore? _traceStore;
  int _next = 0;
  bool get sharedFilesystem => false;
  bool get isClosed => _state is _Closed;
  bool get isConnected => _state is _Connected;

  static Future<AgentClient> connect(Uri uri, {String? token, bool? sharedFilesystem, CancellationToken? cancellation}) async {
    if (token != null) throw ArgumentError('Browser connections use the owner session');
    final origin = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http', path: '/', query: '', fragment: '');
    await restoreServerSignIn(origin, cancellation ?? CancellationToken());
    final client = AgentClient._(uri);
    client._maintaining = client._maintain().catchError((Object error, StackTrace stack) {
      if (!client._ready.isCompleted) client._ready.completeError(error, stack);
    });
    final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
    try {
      await client._ready.future.asCancellable(cancellation == null ? deadline : cancellation.merge(deadline));
      return client;
    } catch (_) { await client.close(); rethrow; }
    finally { deadline.cancel(); }
  }

  void _set(_ConnectionState state) => _state = _transition(_state, state);

  Future<void> _maintain() async {
    var attempt = 0;
    while (!_lifetime.isCancelled) {
      _set(const _Connecting());
      final socket = web.WebSocket(uri.toString());
      final opened = Completer<void>(), dropped = _dropped = Completer<void>();
      var requiresAuthentication = false;
      final hook = CancellationHook(_lifetime, () { socket.close(); if (!dropped.isCompleted) dropped.complete(); });
      _subscriptions.addAll([
        socket.onOpen.listen((_) {
          final origin = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http').origin;
          socket.send(jsonEncode({'type': 'authenticate', 'token': _sessions[origin]}).toJS);
        }),
        socket.onError.listen((_) { if (!opened.isCompleted) opened.completeError(StateError('Could not connect to the server')); }),
        socket.onClose.listen((event) {
          if (event.code == 1008) {
            requiresAuthentication = true;
            _sessions.remove(uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http').origin);
          }
          if (!opened.isCompleted) opened.completeError(StateError('The server closed the connection'));
          if (!dropped.isCompleted) dropped.complete();
          _failPending();
        }),
        socket.onMessage.listen((event) {
          try {
            final raw = event.data.dartify();
            if (raw is! String) return;
            final message = jsonObject(jsonDecode(raw));
            if (message['type'] == 'authenticated') { if (!opened.isCompleted) opened.complete(); return; }
            if (message['method'] is String) {
              events.add(message['method'] == 'happen/event' ? jsonObject(message['params']) : message);
            } else {
              final pending = _pending.remove(message['id']);
              if (message.containsKey('error')) { pending?.completeError(StateError(message['error'].toString())); }
              else { pending?.complete(message['result']); }
            }
          } catch (_) { socket.close(1002, 'Invalid protocol message'); }
        }),
      ]);
      try {
        final handshake = TimeoutCancellationToken(const Duration(seconds: 12));
        try { await opened.future.asCancellable(_lifetime.merge(handshake)); }
        finally { handshake.cancel(); }
        _lifetime.throwIfCancelled();
        _set(_Connected(socket));
        await _request('initialize', {'clientInfo': {'name': 'happen-web', 'version': '0.1.0'},
          'capabilities': {'experimentalApi': true}}, cancellation: _lifetime, timeout: const Duration(seconds: 15));
        socket.send('{"method":"initialized"}'.toJS);
        attempt = 0;
        if (!_ready.isCompleted) _ready.complete();
        events.add({'method': 'connection/ready'});
        await dropped.future;
      } catch (error, stack) {
        if (requiresAuthentication && !_ready.isCompleted) {
          _ready.completeError(const RemoteFailure('Sign in with your owner key', code: 'unauthorized'), stack);
        }
      } finally {
        hook.dispose();
        socket.close();
        for (final subscription in _subscriptions) { await subscription.cancel(); }
        _subscriptions.clear();
        _failPending();
      }
      if (_lifetime.isCancelled) break;
      _set(const _Retrying());
      events.add({'method': 'connection/closed'});
      if (requiresAuthentication) {
        _set(const _Closed());
        await events.close();
        return;
      }
      try {
        await cancellableDelay(Duration(seconds: (1 << attempt.clamp(0, 5)).clamp(1, 20)), _lifetime);
        attempt++;
      } on CancelledException { break; }
    }
  }

  void _failPending() {
    for (final pending in _pending.values) { pending.completeError(StateError('Connection interrupted. The action was not retried.')); }
    _pending.clear();
  }

  Future<Object?> request(String method, [Json params = const {}]) => _request(method, params);

  Future<Json> inspectWorkspace(String path, {required CancellationToken cancellation}) async =>
    jsonObject(await _request('workspace.inspect', {'path': path, 'includeIcon': true}, cancellation: cancellation));

  Future<Json> browseProjectFolders(String query, {required CancellationToken cancellation}) async =>
    jsonObject(await _request('workspace.browse', {'query': query}, cancellation: cancellation,
      timeout: const Duration(seconds: 15)));

  Future<Json> prepareProjectFolder(String kind, String path, {String? remoteUrl,
    required String operationId, required CancellationToken cancellation}) async =>
    jsonObject(await _request('workspace.prepare', {'kind': kind, 'path': path,
      'remoteUrl': remoteUrl, 'operationId': operationId}, cancellation: cancellation,
      timeout: const Duration(minutes: 12)));

  Future<Json> discoverWorkspaces({required List<String> paths, String? repository, String subdirectory = '',
    List<String> subdirectories = const [],
    required CancellationToken cancellation}) async => jsonObject(await _request('workspace.discover',
      {'paths': paths, 'repository': repository, 'subdirectory': subdirectory, 'subdirectories': subdirectories},
      cancellation: cancellation, timeout: const Duration(seconds: 60)));

  Future<Json> gitRequest(String method, Json params, {required CancellationToken cancellation}) async {
    if (!{'git/status', 'git/run', 'git/branches', 'git/diff'}.contains(method)) throw ArgumentError('Unknown Git operation');
    return jsonObject(await _request(method, params, cancellation: cancellation));
  }

  Future<Json> terminalRequest(String method, Json params, {required CancellationToken cancellation}) async {
    if (!{'terminal/open', 'terminal/write', 'terminal/resize', 'terminal/ack', 'terminal/close'}.contains(method)) {
      throw ArgumentError('Unknown terminal operation');
    }
    return jsonObject(await _request(method, params, cancellation: cancellation));
  }

  Future<Json> forkThread(String threadID, {required String lastTurnId, required CancellationToken cancellation}) async =>
    jsonObject(await _request('thread/fork', {
      'threadId': threadID, 'lastTurnId': lastTurnId, 'excludeTurns': true, 'threadSource': 'user',
    }, cancellation: cancellation));

  Future<Json> createSideChat(String parentID, {String prompt = '', List<Json> attachments = const [],
    required CancellationToken cancellation}) async => jsonObject(await _request('session.side.create', {
      'sessionID': parentID, 'prompt': prompt,
      if (attachments.isNotEmpty) 'attachments': attachments,
    }, cancellation: cancellation));

  Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async {
    if (!{'session.context', 'thread/resume', 'thread/read', 'thread/items/list', 'thread/turns/list', 'thread/item/read', 'thread/list', 'thread/image/read'}.contains(method)) {
      throw ArgumentError('Unknown session read');
    }
    return jsonObject(await _request(method, params, cancellation: cancellation));
  }

  Future<Json> goalRequest(String method, Json params, {required CancellationToken cancellation}) async {
    if (!{'thread/goal/get', 'thread/goal/set', 'thread/goal/clear'}.contains(method)) {
      throw ArgumentError('Unknown goal operation');
    }
    return jsonObject(await _request(method, params, cancellation: cancellation));
  }

  Future<void> answerQuestion(String sessionID, String requestID, List<List<String>>? answers, {
    required CancellationToken cancellation,
  }) async {
    await _request(answers == null ? 'session.question.reject' : 'session.question.reply', {
      'sessionID': sessionID, 'requestID': requestID, if (answers != null) 'answers': answers,
    }, cancellation: cancellation);
  }



  Future<Json> searchFiles(String cwd, String query, {required CancellationToken cancellation}) async =>
      jsonObject(await _request('files.search', {'cwd': cwd, 'query': query},
          cancellation: cancellation, timeout: const Duration(seconds: 10)));

  Future<Json> fileSystemRequest(String method, String path, {required CancellationToken cancellation}) async =>
      jsonObject(await _request(method, {'path': path},
          cancellation: cancellation, timeout: const Duration(seconds: 30)));

  Future<Json> searchSkills(String cwd, String query, {String? provider, required CancellationToken cancellation}) async =>
      jsonObject(await _request('skills.search', {'cwd': cwd, 'query': query, 'provider': ?provider},
          cancellation: cancellation, timeout: const Duration(seconds: 10)));

  Future<Json> mcpInventory({bool verbose = false, String? server, String? cwd, required CancellationToken cancellation}) async =>
      jsonObject(await _request('mcp.inventory', {'verbose': verbose, 'server': ?server, 'cwd': ?cwd},
        cancellation: cancellation, timeout: const Duration(seconds: 35)));

  Future<Json> mcpLogin(String server, String loginId, {String? cwd, required CancellationToken cancellation}) async =>
      throw UnsupportedError('MCP sign-in requires a callback configured on the server');

  Future<void> mcpLogout(String server, {String? cwd, required CancellationToken cancellation}) async =>
      _request('mcp.auth.logout', {'server': server, 'cwd': ?cwd}, cancellation: cancellation);

  Future<Json> desktopAuthorization({bool refresh = false, required CancellationToken cancellation}) async =>
      jsonObject(await _request('auth.desktop', {'refresh': refresh}, cancellation: cancellation,
        timeout: const Duration(seconds: 30)));

  Future<Object?> _request(String method, Json params, {CancellationToken? cancellation,
    Duration timeout = const Duration(minutes: 5)}) async {
    cancellation?.throwIfCancelled();
    final state = _state;
    if (state is! _Connected || state.socket.readyState != 1) throw StateError('Server is reconnecting');
    final id = ++_next;
    final deadline = TimeoutCancellationToken(timeout);
    final token = cancellation == null ? deadline.merge(_lifetime) : cancellation.merge(deadline).merge(_lifetime);
    final reply = CancellableCompleter<Object?>(token, onCancel: () {
      _pending.remove(id);
      if (state.socket.readyState != 1) return;
      final cancel = method.startsWith('git/') ? 'git/cancel'
        : method == 'files.search' ? 'files.cancel' : method == 'skills.search' ? 'skills.cancel'
        : method == 'mcp.inventory' ? 'mcp.inventory.cancel' : 'session.read.cancel';
      state.socket.send(jsonEncode({'method': cancel, 'params': {'request_id': id, 'requestId': id}}).toJS);
    });
    _pending[id] = reply;
    state.socket.send(jsonEncode({'id': id, 'method': method, 'params': params}).toJS);
    try { return await reply.future; }
    finally { _pending.remove(id); deadline.cancel(); }
  }

  Future<void> checkConnection({required CancellationToken cancellation}) async {
    await _request('ping', {}, cancellation: cancellation, timeout: const Duration(seconds: 6));
  }

  Future<void> respondClientTool(String id, Json result, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    final state = _state;
    if (state is! _Connected) throw StateError('Server is reconnecting');
    state.socket.send(jsonEncode({'id': id, 'result': result}).toJS);
  }

  Future<TraceStore> startTracing(String directory) async => _traceStore ??= await TraceStore.open(directory, cancellation: _lifetime);
  void traceSession(String sessionID) {}
  TraceContext? eventTrace(Json event) => _traceStore == null ? null :
    traceContextFrom(event['_trace'], sink: _traceStore!.sink, service: 'desktop');

  Future<Json> tracePage(String sessionID, {int after = 0, int? through, required CancellationToken cancellation}) async =>
    jsonObject(await _request('session.trace.page', {'sessionID': sessionID, 'after': after, 'through': through}, cancellation: cancellation));
  Future<Json> traceStatus(String sessionID, {required CancellationToken cancellation}) async =>
    jsonObject(await _request('session.trace.status', {'sessionID': sessionID}, cancellation: cancellation));

  Future<Json> uploadAttachment(String path, {required String name, required String type,
    required CancellationToken cancellation, void Function(int, int)? onProgress}) async {
    final data = await readBrowserFile(path, cancellation);
    final id = newId();
    var complete = false;
    try {
      await _request('attachments.begin', {'upload_id': id, 'name': name, 'type': type, 'size': data.length}, cancellation: cancellation);
      for (var offset = 0; offset < data.length;) {
        final end = (offset + maxAttachmentChunkBytes).clamp(0, data.length);
        await _request('attachments.append', {'upload_id': id, 'offset': offset,
          'data': base64Encode(data.sublist(offset, end))}, cancellation: cancellation);
        offset = end;
        onProgress?.call(offset, data.length);
      }
      final result = jsonObject(await _request('attachments.finish', {'upload_id': id}, cancellation: cancellation));
      complete = true;
      return result;
    } finally { if (!complete) await discardAttachment(id); }
  }

  Future<void> discardAttachment(String id) async {
    if (!isConnected) return;
    try { await _request('attachments.cancel', {'upload_id': id}, timeout: const Duration(seconds: 10)); }
    catch (_) { /* Server connection cleanup releases interrupted uploads. */ }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _lifetime.cancel();
    final state = _state;
    if (state is _Connected) state.socket.close();
    if (_dropped case final dropped? when !dropped.isCompleted) dropped.complete();
    await _maintaining;
    if (!isClosed) _set(const _Closed());
    _failPending();
    await events.close();
    await _traceStore?.close();
  }
}

Future<AgentClient> startSsh(String alias, {String? user, int? port, String? identityFile,
  required CancellationToken cancellation}) => AgentClient.connect(serverSocketUri(Uri.parse(alias)), cancellation: cancellation);

String defaultConfigPath() => '~/.config/happen/config.yaml';

/// All exporters page one immutable actor snapshot, never the transcript.
Future<Json> readContextSnapshot(AgentClient client, String sessionID, {required CancellationToken cancellation}) async {
  final input = <Json>[];
  Json? snapshot;
  String? cursor;
  do {
    final page = await client.sessionRead('session.context', {
      'sessionID': sessionID, 'limit': 200, 'cursor': ?cursor,
    }, cancellation: cancellation);
    snapshot ??= page;
    if (page['snapshotID'] != snapshot['snapshotID']) throw StateError('Context changed during export');
    input.addAll((page['input'] as List).map(jsonObject));
    cursor = page['cursor']?['next'] as String?;
  } while (cursor != null);
  cancellation.throwIfCancelled();
  return {...snapshot, 'input': input}..remove('cursor');
}
