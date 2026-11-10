import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:agent/agent.dart';
import 'package:ai/ai.dart';
import 'package:code_mode/code_mode.dart';
import 'package:protocol/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

import 'src/network.dart';
export 'package:config/config.dart' show defaultConfigPath;
import 'src/client_tools.dart';
import 'src/task_tools.dart';
import 'src/file_search.dart';
import 'src/attachments.dart';
import 'src/questions.dart';
import 'src/git.dart';
import 'src/workspaces.dart';
import 'src/terminals.dart';

part 'src/side_chats.dart';
part 'src/thread_protocol.dart';
part 'src/thread_fork.dart';
part 'src/thread_names.dart';
part 'src/thread_lifecycle.dart';
part 'src/mcp_events.dart';
part 'src/mcp_input.dart';
part 'src/network_lifecycle.dart';
part 'src/goals.dart';
part 'src/git_requests.dart';
part 'src/ssh.dart';

class AgentServer {
  AgentServer._(
    this.directory,
    this.http,
    this.network,
    this.token,
    this.maxAgents,
    this.telemetry,
    this._networkEvents,
  );
  final String directory;
  final HttpServer? http;
  IsolateOwner network;
  final String? token;
  final int maxAgents;
  final Telemetry telemetry;
  final ReceivePort _networkEvents;
  final _lifetime = CancellationToken();
  final _clientTools = ClientToolBridge();
  late final _taskTools = TaskToolBridge(_broadcast);
  late final _questions = SessionQuestions(_broadcast);
  final _files = FileSearch();
  late final _terminals = ServerTerminals((owner, event) {
    for (final client in _clients) {
      if (client.id == owner && !client.cancellation.isCancelled) client.event(event);
    }
  });
  String? socketPath;
  Directory? _socketDirectory;
  FileStat? _socketStat;
  final _clients = <_Client>{};
  final _tasks = <String, _Task>{};
  late final _namingThreads = <String>{};
  late final _gitActions = <String, String>{};
  final _sideForks = <String, Future<_Task>>{};
  final _goals = <String, GoalRuntime>{};
  final _goalRequests = ReceivePort();
  final _goalOperations = <String, CancellationToken>{};
  StreamSubscription<Object?>? _goalSubscription;
  final _activity = StreamController<int>.broadcast();
  final _mcpActivity = StreamController<int>.broadcast();
  final _mcpSubscriptionOwners = <String, Set<String>>{};
  final _requests = <Future<Object?>>{};
  final _imports = <String, Future<String>>{};
  final _mcpDeliveries = <String, Future<void>>{};
  final _mcpOperations = <String, CancellationToken>{};
  final _mcpInputs = <String, ({Json request, Completer<Json> answer, String? owner, String? threadId})>{};
  bool _closing = false;
  bool _networkExited = false;
  late Json _networkConfiguration = const {};
  late _NetworkRecovery _networkRecovery = const _NetworkIdle();
  IsolateOwner? _observedNetwork;
  String? _networkGeneration;
  final int _threadUnloadDelaySecs = 60;
  Timer? _maintenanceTimer;
  Future<Json>? _maintenance;
  Future<TraceStore>? _traces;
  late Future<IsolateOwner>? _catalog = null;
  Future<IsolateOwner> get _serverStore => _catalog ??= startServerStore(directory, cancellation: _lifetime);

  Future<IsolateOwner> _startStore(String id, {bool create = true, bool inMemory = false, Json? fork}) async =>
    startStore(directory, id, create: create, inMemory: inMemory, fork: fork,
      catalog: inMemory ? null : (await _serverStore).port, cancellation: _lifetime);
  Future<TraceStore> get traces => _traces ??= TraceStore.open('$directory/telemetry.sqlite', cancellation: _lifetime);
  int _transfers = 0;

  /// Activity belongs to this server instance, independent of client subscriptions.
  int get activeTaskCount => _tasks.values.where((task) => task.busy).length;
  Stream<int> get activeTaskCounts => _activity.stream;

  /// Durable subscriptions on unarchived threads, including unloaded threads
  /// and watches awaiting an upstream reconnect. Client-only watches are excluded.
  int get mcpSubscriptionCount => _mcpSubscriptionOwners.values.fold(0, (count, subscriptions) => count + subscriptions.length);
  Stream<int> get mcpSubscriptionCounts => _mcpActivity.stream;

  static Future<AgentServer> start({
    required String directory,
    String host = '127.0.0.1',
    int port = 8765,
    String? token,
    String? endpoint,
    String? apiKeyEnv,
    String? openCodeEndpoint,
    String? openCodeSearchEndpoint,
    String? publicUrl,
    String? configPath,
    String? skillsHome,
    String? socketPath,
    int maxAgents = 256,
    bool telemetry = true,
    bool inProcess = false,
  }) async {
    final address = InternetAddress.tryParse(host);
    if (!inProcess && socketPath == null &&
        (address == null || !address.isLoopback) &&
        (token == null || token.isEmpty)) {
      throw ArgumentError(
        'A bearer token is required for a non-loopback listener',
      );
    }
    if (maxAgents < 1 || maxAgents > 1024) {
      throw ArgumentError('maxAgents must be 1..1024');
    }
    if (publicUrl != null) {
      final uri = Uri.tryParse(publicUrl);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
          uri.hasFragment || uri.port < 1 || uri.port > 65535) {
        throw ArgumentError('The public callback URL must be HTTPS without credentials or a fragment');
      }
    }
    await Directory(directory).create(recursive: true);
    if (socketPath != null) {
      socketPath = File(socketPath).absolute.path;
      if (await FileSystemEntity.type(socketPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException('Socket path already exists', socketPath);
      }
    }
    final events = ReceivePort();
    final generation = newId();
    final IsolateOwner network;
    try {
      network = await startNetwork(
        directory,
        endpoint: endpoint,
        apiKeyEnv: apiKeyEnv,
        openCodeEndpoint: openCodeEndpoint,
        openCodeSearchEndpoint: openCodeSearchEndpoint,
        publicUrl: publicUrl,
        configPath: configPath,
        skillsHome: skillsHome,
        events: events.sendPort,
        generation: generation,
      );
    } catch (_) {
      events.close();
      rethrow;
    }
    try {
      final http = inProcess ? null : await HttpServer.bind(
        socketPath == null
            ? host
            : InternetAddress(socketPath, type: InternetAddressType.unix),
        socketPath == null ? port : 0,
      );
      if (socketPath != null) {
        final permissions = await Process.run('chmod', ['600', socketPath]);
        if (permissions.exitCode != 0) {
          await http!.close(force: true);
          throw FileSystemException(
            'Could not restrict socket permissions',
            socketPath,
          );
        }
      }
      final server = AgentServer._(
        directory,
        http,
        network,
        token,
        maxAgents,
        Telemetry(enabled: telemetry),
        events,
      );
      server.socketPath = socketPath;
      server._networkConfiguration = {
        'endpoint': endpoint, 'api_key_env': apiKeyEnv,
        'opencode_endpoint': openCodeEndpoint, 'opencode_search_endpoint': openCodeSearchEndpoint,
        'public_url': publicUrl, 'config_path': configPath, 'skills_home': skillsHome,
      };
      server._networkGeneration = generation;
      server._watchNetwork(network);
      server._goalSubscription = server._goalRequests.listen(server._handleGoalRequest);
      if (socketPath != null) {
        server._socketStat = await File(socketPath).stat();
      }
      events.listen((raw) {
        server._networkEvent(jsonObject(raw));
      });
      final restoringEvents = server._restoreMcpEvents();
      server._requests.add(restoringEvents);
      unawaited(restoringEvents.catchError((Object error) {
        if (!server._closing) traceError(error);
      }).whenComplete(() => server._requests.remove(restoringEvents)));
      http?.listen(server._accept);
      void maintain() {
        unawaited(server.maintain().catchError((Object _) {
          server.telemetry.add('maintenance_failures');
          return <String, dynamic>{};
        }));
      }
      server._maintenanceTimer = Timer.periodic(const Duration(days: 1), (_) => maintain());
      maintain();
      return server;
    } catch (_) {
      events.close();
      await network.close();
      rethrow;
    }
  }

  /// Owns the same agent, persistence and network isolates without a listener.
  static Future<AgentServer> startLocal({
    required String directory,
    String? endpoint,
    String? apiKeyEnv,
    String? openCodeEndpoint,
    String? openCodeSearchEndpoint,
    String? publicUrl,
    String? configPath,
    String? skillsHome,
    bool telemetry = true,
  }) => start(directory: directory, endpoint: endpoint, apiKeyEnv: apiKeyEnv,
    openCodeEndpoint: openCodeEndpoint, openCodeSearchEndpoint: openCodeSearchEndpoint, publicUrl: publicUrl, configPath: configPath,
    skillsHome: skillsHome, telemetry: telemetry, inProcess: true);

  /// One process, using UDS on Unix and authenticated loopback on Windows.
  static Future<AgentServer> startEmbedded({
    required String directory,
    String? endpoint,
    String? openCodeEndpoint,
    String? openCodeSearchEndpoint,
    String? publicUrl,
    String? configPath,
    String? skillsHome,
    bool telemetry = true,
  }) async {
    if (Platform.isWindows) {
      return start(
        directory: directory,
        host: '127.0.0.1',
        port: 0,
        token: newId(),
        endpoint: endpoint,
        openCodeEndpoint: openCodeEndpoint,
        openCodeSearchEndpoint: openCodeSearchEndpoint,
        publicUrl: publicUrl,
        configPath: configPath,
        skillsHome: skillsHome,
        telemetry: telemetry,
      );
    }
    final sockets = await Directory.systemTemp.createTemp('happen-');
    try {
      final permissions = await Process.run('chmod', ['700', sockets.path]);
      if (permissions.exitCode != 0) {
        throw StateError('Could not restrict socket directory permissions');
      }
      final server = await start(
        directory: directory,
        socketPath: '${sockets.path}/s',
        endpoint: endpoint,
        openCodeEndpoint: openCodeEndpoint,
        openCodeSearchEndpoint: openCodeSearchEndpoint,
        publicUrl: publicUrl,
        configPath: configPath,
        skillsHome: skillsHome,
        telemetry: telemetry,
      );
      server._socketDirectory = sockets;
      return server;
    } catch (_) {
      await sockets.delete(recursive: true);
      rethrow;
    }
  }

  Uri get uri => socketPath != null
      ? Uri(scheme: 'unix', path: socketPath)
      : Uri(
          scheme: 'ws',
          host: http!.address.address,
          port: http!.port,
          path: '/ws',
        );

  Future<void> _accept(HttpRequest request) async {
    if (request.headers.value('origin') != null) {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    if (!_closing && request.method == 'GET' && {'/readyz', '/healthz'}.contains(request.uri.path)) {
      request.response.statusCode = 200;
      await request.response.close();
      return;
    }
    if (!_closing &&
        request.method == 'POST' &&
        RegExp(r'^/mcp-events/[a-f0-9]{32}$').hasMatch(request.uri.path)) {
      await _webhook(request);
      return;
    }
    if (_closing ||
        request.uri.path != '/ws' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    // Browser callers must use an authenticated local proxy, not ambient localhost authority.
    if (request.headers.value('origin') != null ||
        (token != null &&
            request.headers.value(HttpHeaders.authorizationHeader) !=
                'Bearer $token')) {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request,
      compression: CompressionOptions.compressionOff);
    socket.pingInterval = const Duration(seconds: 30);
    final client = _Client(socket, directory);
    _clients.add(client);
    socket.listen(
      (raw) async {
        Object? id;
        try {
          if (raw is! String) return; // Plain Codex transport ignores binary frames.
          if (utf8.encode(raw).length > maxClientFrameBytes) {
            throw const FormatException('Invalid or oversized frame');
          }
          final Object? decoded;
          try { decoded = jsonDecode(raw); }
          on FormatException { throw const _RpcError(-32700, 'Parse error'); }
          if (decoded is! Map) throw const _RpcError(-32600, 'Invalid request');
          final request = jsonObject(decoded);
          id = request['id'];
          if (id != null && id is! String && id is! int) throw const _RpcError(-32600, 'Invalid request ID');
          if (request['method'] == null &&
              request.containsKey('id') &&
              (request.containsKey('result') || request.containsKey('error'))) {
            _clientTools.complete(client.id, request);
            return;
          }
          if (request['method'] == 'initialized' && id == null) {
            return;
          }
          if (request['method'] == 'session.read.cancel' && id == null) {
            await _cancelSessionRead(client, request['params']?['request_id']);
            return;
          }
          if (request['method'] == 'files.cancel') {
            if (request['params']?['request_id'] == client.fileSearchId) {
              client.fileSearch?.cancel();
            }
            return;
          }
          if (request['method'] == 'git/cancel') {
            client.gitOperations[request['params']?['requestId']]?.cancel();
            return;
          }
          if (request['method'] == 'skills.cancel') {
            if (request['params']?['request_id'] == client.skillSearchId) client.skillSearch?.cancel();
            return;
          }
          if (request['method'] == 'mcp.inventory.cancel') {
            client.mcpInventories[request['params']?['request_id']]?.cancel();
            return;
          }
          if (request['method'] == 'mcp.auth.login.cancel') {
            client.mcpLogins[request['params']?['request_id']]?.cancel();
            return;
          }
          if (id == null) return; // Unknown notifications never produce replies.
          if (client.inFlight >= 32) {
            throw const _RpcError(-32000, 'Server overloaded; retry later');
          }
          client.inFlight++;
          Future<Object?>? operation;
          try {
            operation = _dispatch(
              requiredString(request, 'method'),
              jsonObject(request['params'] ?? {}),
              client,
              id,
              trace: request['_trace'] is Map ? jsonObject(request['_trace']) : null,
            );
            _requests.add(operation);
            final result = await operation;
            client.send({'id': id, 'result': result});
            client.afterResponse.remove(id)?.call();
          } finally {
            client.afterResponse.remove(id);
            _requests.remove(operation);
            client.inFlight--;
          }
        } catch (error) {
          client.send({
            'id': id,
            'error': {'code': error is _RpcError ? error.code : error is FormatException ? -32602 : -32600,
              'message': error is _RpcError ? error.message : error.toString()},
          });
        }
      },
      onDone: () => _detach(client),
      onError: (Object _) => _detach(client),
    );
  }

  void _detach(_Client client) {
    if (!_clients.remove(client)) return;
    for (final id in client.subscriptions) {
      if (_tasks[id] case final task?) _scheduleUnload(task);
    }
    for (final context in client.sessionTraces.values) {
      withTrace(context, () => traceInstant('websocket.disconnected', category: 'websocket', attributes: {
        'connection.id': client.id, 'close.code': client.socket?.closeCode,
        'queued_events': client._queuedFrames, 'queued_bytes': client._queuedBytes,
      }));
    }
    client.cancellation.cancel();
    unawaited(_terminals.detach(client.id).catchError((Object _) {}));
    unawaited(client.attachments.close());
    _clientTools.detach(client.id);
    if (!_networkExited) {
      unawaited(
        callIsolate(network.port, 'mcp.detach', {
          'owner': client.id,
        }).catchError((Object _) => null),
      );
    }
  }

  Future<void> _webhook(HttpRequest request) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 15));
    final cancellation = deadline.merge(_lifetime);
    final bytes = <int>[];
    final input = StreamIterator(request);
    try {
      if (request.headers.value('origin') != null) {
        request.response.statusCode = 403;
        return;
      }
      while (await input.moveNext().asCancellable(
        cancellation,
        onCancel: () => unawaited(input.cancel()),
      )) {
        bytes.addAll(input.current);
        if (bytes.length > 256 * 1024) {
          request.response.statusCode = 413;
          return;
        }
      }
      final result = jsonObject(
        await _callNetwork('mcp.webhook', {
          'subscription_id': request.uri.pathSegments.last,
          'body': bytes,
          'headers': {
            for (final name in [
              'webhook-id',
              'webhook-timestamp',
              'webhook-signature',
              'x-mcp-subscription-id',
            ])
              name: request.headers.value(name),
          },
        }, cancellation: cancellation),
      );
      request.response.statusCode = result['status'] as int;
      if (result['body'] != null) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result['body']));
      }
    } catch (_) {
      request.response.statusCode = 400;
    } finally {
      deadline.cancel();
      unawaited(input.cancel().catchError((Object _) {}));
      await request.response.close();
    }
  }

  Future<Object?> _dispatch(String method, Json params, _Client client, Object requestId, {Json? trace}) async {
    final operations = method.startsWith('git/') ? client.gitOperations : client.sessionReads;
    final preparation = method == 'session.side.create' || method.startsWith('git/') || method.startsWith('workspace.') || method.startsWith('terminal/')
      ? operations.putIfAbsent(requestId, CancellationToken.new) : null;
    try {
      // Export reads must not recursively record their own trace pages.
      if (method.startsWith('session.trace.') || trace == null ||
          {'session.create', 'task.start'}.contains(method) && params['tracing'] != true) {
        return await withTrace(null, () => _dispatchUntraced(method, params, client, requestId));
      }
      final store = await traces;
      final forking = {'session.side.create', 'thread/fork'}.contains(method);
      final incoming = traceContextFrom(trace, sink: store.sink, service: 'server');
      if (incoming == null) return await withTrace(null, () => _dispatchUntraced(method, params, client, requestId));
      final context = forking && incoming.session != null
        ? TraceContext(sink: store.sink, service: 'server') : incoming;
      if (!forking) {
        if ((params['sessionID'] ?? params['task_id']) case final String session) context.session = session;
      }
      return await withTrace(context, () {
        traceReceive(trace, 'websocket', attributes: {'rpc.method': method, 'rpc.id': requestId});
        return traceAsync('server.$method', () {
          client.requestTraces[requestId] = currentTrace!;
          return _dispatchUntraced(method, params, client, requestId);
        },
          category: 'rpc', attributes: {'rpc.id': requestId, 'connection.id': client.id,
            if (forking) 'parent.session_id': params['threadId'] ?? params['sessionID'],
            if (forking && params['lastTurnId'] != null) 'fork.last_turn_id': params['lastTurnId']});
      });
    } finally {
      if (preparation != null) { operations.remove(requestId); preparation.cancel(); }
    }
  }

  Future<void> _cancelSessionRead(_Client client, Object? requestId) async {
    client.sessionReads[requestId]?.cancel();
    if (_tasks[client.sideCreations[requestId]] case final side?) await _closeSide(side);
  }

  Future<Object?> _dispatchUntraced(String method, Json params, _Client client, Object requestId) async {
    _lifetime.throwIfCancelled();
    if (_closing) throw StateError('Server is shutting down');
    if (method == 'initialize') {
      if (client.initialized) throw const _RpcError(-32600, 'Already initialized');
      final info = jsonObject(params['clientInfo']);
      requiredString(info, 'name'); requiredString(info, 'version');
      client.initialized = true;
      client.optOutNotifications.addAll((params['capabilities']?['optOutNotificationMethods'] as List? ?? []).cast<String>());
      return {'userAgent': 'happen/0.1.0', 'serverInfo': {'name': 'happen', 'version': '0.1.0'}, 'platformFamily': Platform.operatingSystem};
    }
    if (!client.initialized) throw const _RpcError(-32600, 'Not initialized');
    if (method == 'workspace.inspect') {
      return inspectWorkspace(requiredString(params, 'path'), client.sessionReads[requestId]!.merge(client.cancellation).merge(_lifetime));
    }
    if (method == 'workspace.discover') {
      final cancellation = client.sessionReads[requestId]!.merge(client.cancellation).merge(_lifetime);
      final paths = (params['paths'] as List? ?? []).cast<String>().toSet();
      if (paths.length > 1000) throw ArgumentError('Too many project roots');
      final history = await listThreads(directory, {'limit': 100}, cancellation: cancellation);
      for (final thread in (history['data'] as List).map(jsonObject)) {
        if (thread['cwd'] is String) paths.add(thread['cwd'] as String);
      }
      return discoverWorkspaces(paths.toList(), params['repository'] as String?,
        params['subdirectory'] as String? ?? '', cancellation,
        subdirectories: (params['subdirectories'] as List? ?? []).cast<String>());
    }
    if (method.startsWith('git/')) return _gitRequest(method, params, client, requestId);
    if (method.startsWith('terminal/')) {
      return _terminals.request(client.id, method, params, client.sessionReads[requestId]!.merge(client.cancellation).merge(_lifetime));
    }
    if (method.startsWith('thread/') || method.startsWith('turn/')) return _threadRequest(method, params, client, requestId);
    if (method == 'session.read.cancel') {
      await _cancelSessionRead(client, params['request_id']);
      return null;
    }
    final receivedAt = DateTime.now().toUtc().toIso8601String();
    final identityKey = method.startsWith('session.') ? 'sessionID' : 'task_id';
    if (method.startsWith('session.') && params['sessionID'] is String) {
      params = {...params, 'task_id': params['sessionID']}..remove('sessionID');
    }
    if (method.startsWith('attachments.')) return client.attachments.handle(method, params);
    if (method == 'task.start' || method == 'task.send' || method == 'session.side.create') {
      if (params.containsKey('message_id')) validateTaskId(requiredString(params, 'message_id'));
      final cancellation = client.sessionReads[requestId]?.merge(client.cancellation) ?? client.cancellation;
      final claimed = await client.attachments.claim(params['attachments']);
      var committed = false;
      try {
      final prompt = params['prompt'] ?? '';
      if (prompt is! String) throw const FormatException('Prompt must be text');
      final envelope = {...params}..remove('attachments');
      final attachments = await prepareInputAttachments(claimed.parts,
        cancellation: cancellation,
        envelopeBytes: utf8.encode(jsonEncode({'id': requestId, 'method': method, 'params': envelope})).length);
      if (method != 'session.side.create' || prompt.isNotEmpty || attachments.isNotEmpty) {
        validateUserInput(prompt, attachments);
      }
      params = {...params, 'prompt': prompt, if (attachments.isNotEmpty) 'attachments': attachments};
      cancellation.throwIfCancelled();
      final result = await _dispatchPrepared(method, params, client, requestId, receivedAt, identityKey);
      committed = true;
      return result;
      } finally {
        await client.attachments.release(claimed.ids, committed: committed);
      }
    }
    if ({'session.context',
      'session.trace.page', 'session.trace.status'}.contains(method)) {
      final operation = CancellationToken();
      client.sessionReads[requestId] = operation;
      try { return await _dispatchPrepared(method, params, client, requestId, receivedAt, identityKey); }
      finally { client.sessionReads.remove(requestId); operation.cancel(); }
    }
    return _dispatchPrepared(method, params, client, requestId, receivedAt, identityKey);
  }

  Future<Object?> _dispatchPrepared(String method, Json params, _Client client, Object requestId, String receivedAt, String identityKey) async {
    final cancellation = client.sessionReads[requestId]?.merge(client.cancellation) ?? client.cancellation;
    if (method == 'mcp.input.list') return _listMcpInputs(client, params['threadId'] as String?);
    if (method == 'mcp.input.reply') { _replyMcpInput(client, params); return null; }
    if (method.startsWith('mcp.') && params['threadId'] != null) {
      final id = requiredString(params, 'threadId'); validateTaskId(id);
      final page = await _readSession(_tasks[id] ?? _Task(id, null), 'thread/read', {'includeTurns': false}, cancellation);
      params = {...params, 'task_id': id, 'cwd': page['thread']['cwd']};
    }
    if (method == 'mcp.auth.login' || method == 'mcp.auth.logout') {
      final deadline = TimeoutCancellationToken(const Duration(minutes: 5));
      client.mcpLogins[requestId] = deadline;
      try {
        return await _callNetwork(method, {...params, 'owner': client.id},
          onEvent: client.event, cancellation: deadline.merge(client.cancellation));
      } finally {
        client.mcpLogins.remove(requestId);
        deadline.cancel();
      }
    }
    if (method == 'mcp.inventory') {
      final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
      client.mcpInventories[requestId] = deadline;
      try {
        return await _callNetwork(method, {...params, 'owner': client.id},
          cancellation: deadline.merge(client.cancellation));
      } finally {
        client.mcpInventories.remove(requestId);
        deadline.cancel();
      }
    }
    if (method.startsWith('mcp.')) {
      if (!{
        'mcp.status',
        'mcp.reload',
        'mcp.auth.logout',
        'mcp.auth.callback',
        'mcp.request',
        'mcp.events.subscribe',
        'mcp.events.unsubscribe',
        'mcp.events.subscriptions',
      }.contains(method)) {
        throw ArgumentError('Unknown MCP client operation');
      }
      var owner = client.id;
      if (method.startsWith('mcp.events.') && params['threadId'] != null) {
        final id = requiredString(params, 'threadId'); validateTaskId(id);
        if (method == 'mcp.events.subscribe') {
          final page = await _readSession(_tasks[id] ?? _Task(id, null), 'thread/read', {'includeTurns': false}, cancellation);
          if (page['archived'] == true) throw StateError('Restore the thread before subscribing to events');
          if (page['thread']['ephemeral'] == true) throw StateError('MCP event subscriptions require a saved thread');
        }
        owner = 'thread:$id';
      }
      return _callNetwork(method, {
        ...params,
        'owner': owner,
      }, cancellation: client.cancellation);
    }
    switch (method) {
      case 'client.capabilities':
        if (params.isEmpty || params.entries.any((entry) => !{'questions', 'mcp_inputs'}.contains(entry.key) || entry.value is! bool)) {
          throw const FormatException('Provide boolean client capabilities');
        }
        if (params['questions'] case final bool value) client.questions = value;
        if (params['mcp_inputs'] case final bool value) client.mcpInputs = value;
        return null;
      case 'ping':
        return {'version': '0.1.0'};
      case 'files.search':
        client.fileSearch?.cancel();
        final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
        client.fileSearch = deadline;
        client.fileSearchId = requestId;
        try {
          return await _files.search(params, deadline.merge(client.cancellation));
        } finally {
          if (identical(client.fileSearch, deadline)) {
            client.fileSearch = null;
            client.fileSearchId = null;
          }
          deadline.cancel();
        }
      case 'skills.search':
        client.skillSearch?.cancel();
        final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
        client.skillSearch = deadline;
        client.skillSearchId = requestId;
        try {
          return await _callNetwork(method, {...params, 'owner': client.id},
            cancellation: deadline.merge(client.cancellation));
        } finally {
          if (identical(client.skillSearch, deadline)) {
            client.skillSearch = null;
            client.skillSearchId = null;
          }
          deadline.cancel();
        }
      case 'providers.list':
        return _callNetwork(
          'providers.list',
          {},
          cancellation: client.cancellation,
        );
      case 'auth.desktop':
        // Access credentials are only available to the local desktop connection.
        // Audio and transcription never pass through the task WebSocket.
        if (socketPath == null) throw StateError('Desktop authorization requires a local Unix socket');
        return _callNetwork(method, {
          'refresh': params['refresh'] == true, 'owner': client.id,
        }, cancellation: client.cancellation);
      case 'auth.login':
      case 'auth.cancel':
      case 'auth.logout':
        return _callNetwork(
          method,
          {...params, 'owner': client.id},
          onEvent: client.event,
          cancellation: client.cancellation,
        );
      case 'telemetry':
        return {
          'active_tasks': activeTaskCount,
          'active_mcp_subscriptions': mcpSubscriptionCount,
          'resident_tasks': _tasks.length,
          'connected_clients': _clients.length,
          'pending_messages': _tasks.values.fold<int>(0, (count, task) => count + task.pending.length),
          'rss_bytes': ProcessInfo.currentRss,
          ...telemetry.snapshot(),
        };
      case 'session.trace.page':
      case 'session.trace.status':
        final id = requiredString(params, 'task_id');
        validateTaskId(id);
        final after = params['after'] as int? ?? 0;
        final through = params['through'] as int?;
        if (after < 0 || through != null && through < after) throw const FormatException('Invalid trace cursor');
        if (_traces == null && !await File('$directory/telemetry.sqlite').exists()) {
          return method == 'session.trace.status' ? {'categories': <String, int>{}}
            : {'through': through ?? 0, 'after': through ?? 0, 'done': true, 'events': <Json>[]};
        }
        final store = await traces;
        if (method == 'session.trace.status') return store.status(id, cancellation: cancellation);
        return store.page(id, after: after, through: through, cancellation: cancellation);
      case 'maintenance.run':
        return maintain();
      case 'task.start':
        final config = await _config(params);
        final id = await _newTaskId(config, client.cancellation);
        bindTraceSession(id);
        if (params['client_tools'] != null) {
          _clientTools.register(
            id,
            client.id,
            params['client_tools'],
            client.send,
          );
        }
        final task = _Task(id, config);
        _subscribe(client, id);
        _begin(
          task,
          params['prompt'] as String,
          settings: {...params, 'sent_at': receivedAt}..remove('settings'),
        );
        // Publish the durable session before acknowledging creation. Discovery
        // must not depend on the creating desktop saving a sidebar reference.
        await task.ready!.future.asCancellable(client.cancellation);
        return {identityKey: id};
      case 'history.import':
        final targetDirectory = directory;
        final source = requiredString(params, 'path');
        final operationId = params['operation_id'] as String?;
        final pending = _imports[operationId];
        if (pending != null) return {'task_id': await pending.asCancellable(client.cancellation)};
        _transfers++;
        final imported = _importHistory(targetDirectory, source, operationId, client.cancellation);
        if (operationId != null) _imports[operationId] = imported;
        try {
          final id = await imported;
          return {'task_id': id};
        } finally {
          unawaited(_imports.remove(operationId));
          _transfers--;
        }
      default:
        final id = requiredString(params, 'task_id');
        validateTaskId(id);
        _subscribe(client, id);
        if (method == 'session.context') return _contextPage(id, params, client, cancellation);
        if (method == 'session.question.list') return {'data': _questions.list(id)};
        if (method == 'session.question.reply' || method == 'session.question.reject') {
          final requestID = requiredString(params, 'requestID');
          if (method == 'session.question.reply') {
            await _questions.reply(id, requestID, params['answers'], send: (prompt) async {
              await _dispatchUntraced('task.send', {'task_id': id, 'prompt': prompt, 'delivery': 'steer'}, client, requestId);
            });
          } else {
            _questions.reject(id, requestID);
          }
          return null;
        }
        var task = _tasks[id] ?? _Task(id, null);
        if (task.backgroundMaintenance case final maintenance?) {
          await maintenance.future.asCancellable(cancellation);
          _lifetime.throwIfCancelled();
          task = _tasks[id] ?? _Task(id, null);
        }
        // Reads and input admission share the writer's ownership transitions.
        // Recheck after each wait: completion may have started a queued turn.
        if ({'history.page',
          'session.side.create', 'session.inbox', 'session.inbox.update', 'session.inbox.cancel',
          'task.send', 'task.compact', 'task.retry'}.contains(method)) {
          while (task.maintenance || task.finishing || task.busy && task.writer == null) {
            await (task.maintenance ? task.maintenanceDone!.future
              : task.finishing ? task.running! : task.ready!.future).asCancellable(cancellation);
            task = _tasks[id] ?? _Task(id, null);
          }
        }
        if (method == 'session.side.create') return _createSide(task, params, client, requestId, cancellation);
        if (method == 'session.side.list') {
          final sides = _tasks.values.where((side) => side.sideParentID == id && !side.disposing).toList();
          for (final side in sides) {
            _subscribe(client, side.id);
          }
          return {'data': sides.map(_sideInfo).toList()};
        }
        if (method == 'session.side.close') {
          if (task.sideParentID == null) throw StateError('Session is not a side chat');
          await _closeSide(task);
          return null;
        }
        if (task.sideParentID != null &&
            {'task.archive', 'task.unarchive', 'history.export'}.contains(method)) {
          throw StateError('Side chats are ephemeral; close the side chat to discard it');
        }
        if (task.disposing) throw StateError('Side chat is closing');
        if (method == 'session.inbox') {
          if (task.busy && task.writer == null) await task.ready?.future.asCancellable(cancellation);
          var page = task.memoryStore != null || File('$directory/tasks/$id/history.sqlite').existsSync()
            ? await _readSession(task, method, params, cancellation)
            : <String, dynamic>{'needsProjection': true};
          if (page['needsProjection'] == true) {
            task = _tasks[id] ?? task;
            while (task.maintenance) {
              await task.maintenanceDone!.future.asCancellable(cancellation);
              task = _tasks[id] ?? task;
            }
            await _withWriter(task, (writer) => callIsolate(writer.port, 'session.prepare', {}, cancellation: cancellation));
            page = await _readSession(task, method, params, cancellation);
          }
          final current = _tasks[id] ?? task;
          return {...page, 'questions': _questions.list(id), 'running': current.busy,
            'status': current.retryStatus ?? {'type': current.busy ? 'busy' : 'idle'}};
        }
        if (method == 'session.inbox.update' || method == 'session.inbox.cancel') {
          final inboxID = requiredString(params, 'inboxID');
          final delivery = method == 'session.inbox.update' ? requiredString(params, 'delivery') : null;
          if (delivery != null && !{'steer', 'queue'}.contains(delivery)) {
            throw ArgumentError('Delivery must be steer or queue');
          }
          if (task.busy && task.writer == null) await task.ready?.future.asCancellable(cancellation);
          if (task.startingInputID == inboxID) throw StateError('Message is already starting');
          Json? starting;
          await _withWriter(task, (writer) async {
            final changed = await callIsolate(writer.port, 'session.inbox.update', {
              'inboxID': inboxID, 'delivery': delivery,
            }, cancellation: cancellation);
            if (changed != null) _broadcast(id, jsonObject(changed));
            final sourceID = inboxID.replaceFirst(RegExp(r'^msg_'), '');
            final index = task.pending.indexWhere((item) => item['id'] == sourceID);
            task.offered.remove(sourceID);
            if (index >= 0) {
              if (delivery == null) {
                task.pending.removeAt(index);
                task.pendingTraces.remove(sourceID);
                task.mcpInputs.remove(sourceID);
              } else {
                final updated = task.pending[index] = {...task.pending[index], 'delivery': delivery};
                if (task.busy) _offerSteering(task, updated);
              }
            }
            if (!task.busy && delivery == 'steer') {
              final inbox = await _readSession(task, 'session.inbox', {}, cancellation);
              task.pending
                ..clear()
                ..addAll((inbox['data'] as List).map(jsonObject));
              starting = task.pending.where((item) => 'msg_${item['id']}' == inboxID).firstOrNull;
              if (starting != null) task.startingInputID = inboxID;
            }
            return null;
          });
          if (starting case final item?) {
            try {
              _begin(task, item['prompt'] as String, settings: {
                'message_id': item['id'], 'sent_at': item['created_at'],
                if (item['attachments'] != null) 'attachments': item['attachments'],
                if (item['reasoning'] != null) 'reasoning': item['reasoning'],
              });
            } catch (_) {
              task.startingInputID = null;
              rethrow;
            }
          }
          return null;
        }
        if (method == 'tools.register') {
          return _clientTools.register(
            id,
            client.id,
            params['tools'],
            client.send,
          );
        }
        if (method == 'task.subscribe') {
          return {identityKey: id, 'running': task.busy, 'pending': task.pending,
            'status': task.retryStatus ?? {'type': task.busy ? 'busy' : 'idle'}};
        }
        if (method == 'task.archive' || method == 'task.unarchive') {
          await _archive(task, method == 'task.archive');
          return {identityKey: id, 'archived': method == 'task.archive'};
        }
        if (method == 'task.cancel') {
          task.cancelled = true;
          if (task.busy && task.writer == null) await task.ready?.future.asCancellable(client.cancellation);
          if (task.finishing) await task.running;
          await _discardPending(task, 'cancelled');
          final agent = task.agent;
          task.codeInterrupt?.interrupt();
          if (agent != null) await callIsolate(agent.port, 'cancel', {});
          return null;
        }
        if (method == 'task.send' || method == 'task.compact') {
          final mode = params['delivery'] as String? ?? 'queue';
          if (!{'steer', 'queue'}.contains(mode)) {
            throw ArgumentError('Delivery must be steer or queue');
          }
          if (method == 'task.send' && task.busy && params['reasoning'] != null) {
            await task.ready?.future.asCancellable(client.cancellation);
            final config = task.config;
            if (config == null) throw StateError('Task configuration is unavailable');
            final effort = requiredString(params, 'reasoning');
            final baseline = jsonObject(config['provider_settings']);
            if (config['reasoning_updates'] != true && effort != baseline['reasoning']) {
              throw ArgumentError('Reasoning effort is fixed for this task');
            }
            await _callNetwork('validate_settings', {
              'provider': config['provider'],
              'model': config['model'],
              'model_info': config['model_info'],
              'settings': {...baseline, 'reasoning': effort},
            }, cancellation: client.cancellation);
            // Validation can outlive the current turn. Admit against its latest owner.
            task = _tasks[id] ?? task;
          }
          while (task.maintenance || task.finishing || task.busy && task.writer == null) {
            await (task.maintenance ? task.maintenanceDone!.future
              : task.finishing ? task.running! : task.ready!.future).asCancellable(cancellation);
            task = _tasks[id] ?? _Task(id, null);
          }
          if (method == 'task.send' && task.busy) {
            if (task.cancelled) throw StateError('Task is stopping');
            if (task.pending.length >= 32) {
              throw StateError('Pending message limit reached');
            }
            if (params.keys.any(
              (key) => !{'task_id', 'prompt', 'message_id', 'attachments', 'delivery', 'reasoning', 'turnId'}.contains(key),
            )) {
              throw ArgumentError('Change task settings between turns');
            }
            final prompt = params['prompt'] as String;
            final pendingBytes = task.pending.fold<int>(0, (size, message) => size + utf8.encode(message['prompt'] as String).length);
            if (pendingBytes + utf8.encode(prompt).length > 512 * 1024) {
              throw StateError('Pending messages exceed 512 KiB');
            }
            final message = <String, dynamic>{
              'id': params['message_id'] ?? newId(),
              'prompt': prompt,
              if (params['attachments'] != null) 'attachments': params['attachments'],
              'delivery': mode,
              'created_at': receivedAt,
              if (params['reasoning'] != null) 'reasoning': params['reasoning'],
            };
            if (utf8.encode(jsonEncode([...task.pending, message])).length > maxClientFrameBytes - 1024) {
              throw StateError('Pending messages exceed the 64 MiB transport budget');
            }
            final activeTurnId = task.protocolState['turnID'];
            await _withWriter(task, (writer) async {
              final admitted = jsonObject(await callIsolate(writer.port, 'append', {
                'type': 'input.pending', 'data': message,
              }, cancellation: client.cancellation));
              task.pending.add(message);
              if (currentTrace case final context?) task.pendingTraces[message['id'] as String] = context;
              _broadcast(id, admitted);
              _offerSteering(task, message);
              return null;
            });
            return {
              identityKey: id,
              if (identityKey == 'sessionID') 'inboxID': 'msg_${message['id']}' else 'message_id': message['id'],
              'delivery': mode,
              if (mode == 'steer') 'turnId': activeTurnId,
            };
          }
          _begin(
            task,
            params['prompt'] as String? ?? '',
            compact: method == 'task.compact',
            settings: {...params, 'sent_at': receivedAt},
          );
          return {identityKey: id};
        }
        if (method == 'history.page') {
          return _withWriter(
            task,
            (writer) => callIsolate(writer.port, 'history', {
              'after': params['after'] ?? 0,
              'limit': params['limit'] ?? 100,
            }, cancellation: client.cancellation),
          );
        }
        if (method == 'history.export') {
          if (task.busy) throw StateError('Export requires an idle task');
          return _withWriter(
            task,
            (writer) => callIsolate(writer.port, 'export', {
              'path': requiredString(params, 'path'),
            }, cancellation: client.cancellation),
          );
        }
        throw StateError('Unknown method: $method');
    }
  }

  Future<Json> _contextPage(String id, Json params, _Client client, CancellationToken cancellation) async {
    final cursor = params['cursor'] == null ? null
      : jsonObject(jsonDecode(utf8.decode(base64Url.decode(params['cursor'] as String))));
    final snapshotID = cursor == null ? newId() : requiredString(cursor, 'snapshot');
    final Json snapshot;
    if (cursor == null) {
      snapshot = await _agentContext(id, cancellation);
    } else {
      final saved = client.contextSnapshots[snapshotID];
      if (saved == null || saved['sessionID'] != id) throw const FormatException('Context snapshot expired; refresh context');
      snapshot = saved;
    }
    cancellation.throwIfCancelled();
    final input = snapshot['input'] as List;
    final start = cursor == null ? 0 : cursor['after'] as int;
    if (start < 0 || start >= input.length && start != 0) throw const FormatException('Invalid context cursor');
    final metadata = {...snapshot}..remove('input');
    final limit = (params['limit'] as int? ?? 100).clamp(1, 200);
    final page = <Json>[];
    var bytes = utf8.encode(jsonEncode(metadata)).length;
    if (bytes > maxClientFrameBytes - 1024 * 1024) {
      throw const FormatException('Context envelope exceeds the WebSocket frame budget');
    }
    for (final raw in input.skip(start).take(limit)) {
      final item = jsonObject(raw), size = utf8.encode(jsonEncode(raw)).length;
      if (page.isNotEmpty && bytes + size > maxClientFrameBytes ~/ 2) break;
      if (bytes + size > maxClientFrameBytes - 1024 * 1024) {
        throw const FormatException('Context item exceeds the WebSocket frame budget');
      }
      page.add(item);
      bytes += size;
    }
    final more = start + page.length < input.length;
    if (more) {
      // Only paginated inspections retain a snapshot; never retain a transcript
      // cache or reconstruct later pages from a changed live buffer.
      client.contextSnapshots[snapshotID] = snapshot;
      while (client.contextSnapshots.length > 4) { client.contextSnapshots.remove(client.contextSnapshots.keys.first); }
    } else {
      client.contextSnapshots.remove(snapshotID);
    }
    return {...metadata, 'snapshotID': snapshotID, 'input': page, 'cursor': {
      if (more) 'next': base64Url.encode(utf8.encode(jsonEncode({'snapshot': snapshotID, 'after': start + page.length}))),
    }};
  }

  Json _agentConfig(String id, Json config) {
    if (config['provider'] != 'openai' || !_clients.any((client) =>
        client.questions && client.subscriptions.contains(id))) return config;
    return {...config, 'provider_settings': {
      ...jsonObject(config['provider_settings']), 'request_user_input': true,
      'default_mode_request_user_input': true,
    }};
  }

  Future<Json> _agentContext(String id, CancellationToken cancellation) async {
    while (true) {
      cancellation.throwIfCancelled();
      final task = _tasks[id] ?? _Task(id, null);
      if (task.maintenance) {
        await task.maintenanceDone!.future.asCancellable(cancellation);
        continue;
      }
      if (task.busy && task.finishing) {
        await task.running!.asCancellable(cancellation);
        continue;
      }
      if (task.busy && task.agent == null) {
        await task.ready!.future.asCancellable(cancellation);
        continue;
      }
      final running = task.busy;
      final pending = task.pending.toList();
      final context = jsonObject(await _withWriter(task, (writer) async {
        if (task.agent case final live?) {
          return callIsolate(live.port, 'context', {}, cancellation: cancellation);
        }
        // An idle thread uses the very same actor and restore operation as
        // inference, without admitting a turn or doing provider/tool I/O.
        final config = jsonObject(await callIsolate(writer.port, 'metadata', {'key': 'config'}, cancellation: cancellation));
        final restored = await startAgent(taskId: id, config: _agentConfig(id, config),
          writer: writer.port, network: network.port, taskTools: _taskTools.port,
          clientTools: _clientTools.port, questions: _questions.port, codeInterrupt: 0);
        try {
          return await callIsolate(restored.port, 'context', {}, cancellation: cancellation);
        } finally { await restored.close(); }
      }));
      return {...context, 'running': running, 'pending': pending};
    }
  }

  void _forgetIdle(_Task task) {
    if (task.loaded) {
      _scheduleUnload(task);
    } else if (task.memoryStore == null && task.writer == null && !task.busy && !task.maintenance &&
        task.pending.isEmpty && !_goals.containsKey(task.id) && identical(_tasks[task.id], task)) {
      _tasks.remove(task.id);
    }
    // Publish after any queued turn has been admitted, without a false idle gap.
    _activity.add(activeTaskCount);
  }

  Future<String> _importHistory(String targetDirectory, String source,
    String? operationId, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    if (operationId != null) {
      validateTaskId(operationId);
      final tasks = Directory('$directory/tasks');
      if (await tasks.exists()) {
        await for (final entry in tasks.list(followLinks: false)) {
          cancellation.throwIfCancelled();
          if (entry is! Directory) continue;
          final id = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
          try { validateTaskId(id); } on FormatException { continue; }
          if (!await File('${entry.path}/history.sqlite').exists()) continue;
          while (true) {
            cancellation.throwIfCancelled();
            final task = _tasks[id] ?? _Task(id, null);
            // Await ownership transitions, never a SQLite lock or a polling timer.
            if (task.maintenanceDone case final done?) {
              await done.future.asCancellable(cancellation);
              continue;
            }
            if (task.finishing) {
              await task.running!.asCancellable(cancellation);
              continue;
            }
            if (task.busy && task.writer == null) {
              await task.ready!.future.asCancellable(cancellation);
              continue;
            }
            final value = await _withWriter(task, (writer) => callIsolate(writer.port,
              'metadata', {'key': 'import_operation'}, cancellation: cancellation));
            if (value == operationId) return id;
            break;
          }
        }
      }
    }
    cancellation.throwIfCancelled();
    return importHistory(targetDirectory, source, operationId: operationId,
      taskIds: (await _acquireNetwork(cancellation)).port, catalog: (await _serverStore).port, cancellation: cancellation);
  }

  Future<void> _archive(_Task task, bool archived) async {
    if (task.maintenance) throw StateError('Task has a pending maintenance operation');
    task.goalContinuation?.cancel();
    task.maintenance = true;
    final settled = task.maintenanceDone = Completer<void>();
    _tasks[task.id] = task;
    IsolateOwner? writer;
    try {
      if (task.busy) {
        task.cancelled = true;
        task.codeInterrupt?.interrupt();
        if (task.agent != null) await callIsolate(task.agent!.port, 'cancel', {});
        await task.running;
      }
      _lifetime.throwIfCancelled();
      if (archived) {
        for (final side in _tasks.values.where((side) => side.sideParentID == task.id).toList()) {
          await _closeSide(side);
        }
      }
      writer = task.memoryStore ?? task.writer ?? await _startStore(task.id, create: false);
      if (archived) await _discardPending(task, 'archived', writer: writer);
      final event = jsonObject(await callIsolate(writer.port, 'archive', {'archived': archived}, cancellation: _lifetime));
      // Publish the committed membership change before draining resources. MCP
      // initialization or remote cleanup must not hold the archive UI open.
      _broadcast(task.id, event);
      if (archived) {
        _setMcpSubscriptions(task.id, {});
        final index = await _serverStore;
        await callIsolate(index.port, 'mcp.forget', {'threadId': task.id}, cancellation: _lifetime);
        _goals.remove(task.id);
        _clientTools.archive(task.id);
        for (final client in _clients) {
          client.subscriptions.remove(task.id);
          client.observations.remove(task.id);
          client.contextSnapshots.removeWhere((_, snapshot) => snapshot['sessionID'] == task.id);
          client.sessionTraces.remove(task.id);
        }
        await _taskTools.release(task.id);
        await callIsolate(network.port, 'agents.forget', {'task_id': task.id}, cancellation: _lifetime);
        // Archive already cleared desired subscriptions in its own commit. Do
        // not start a second writer operation while holding maintenance here.
        await callIsolate(network.port, 'mcp.detach', {'owner': 'thread:${task.id}', 'persist': false}, cancellation: _lifetime);
      }
    } finally {
      try { await writer?.close(); if (task.writer == writer) task.writer = null; }
      finally {
        if (archived) {
          task.loaded = false;
          if (identical(task.memoryStore, writer)) task.memoryStore = null;
          task.unloadTimer?.cancel(); task.unloadTimer = null;
        }
        task.maintenance = false;
        task.maintenanceDone = null;
        settled.complete();
        _forgetIdle(task);
      }
    }
  }

  /// Coalesces startup, daily and manual maintenance into one cancellable sweep.
  /// Archived transcripts remain durable, matching Codex's archive policy.
  Future<Json> maintain() {
    _lifetime.throwIfCancelled();
    return _maintenance ??= _maintain().whenComplete(() => _maintenance = null);
  }

  Future<Json> _maintain() async {
    var checked = 0, archived = 0, removed = 0, errors = 0;
    await _serverStore;
    // Only archived histories need checkpointing. Inventory comes from the
    // catalog, so routine maintenance only visits registered threads.
    final ids = <String>[];
    String? cursor;
    do {
      final page = await listThreads(directory, {'archived': true, 'cursor': ?cursor, 'limit': 500}, cancellation: _lifetime);
      ids.addAll((page['data'] as List).map((thread) => thread['id'] as String));
      cursor = page['nextCursor'] as String?;
    } while (cursor != null);
    for (final id in ids) {
      _lifetime.throwIfCancelled();
      if (_clients.any((client) => client.id == id) || _tasks.containsKey(id)) continue;
      final task = _Task(id, null);
      final maintenance = task.backgroundMaintenance = Completer<void>();
      try {
        final result = jsonObject(await _withWriter(task, (writer) => callIsolate(writer.port, 'maintain', {}, cancellation: _lifetime)));
        checked++;
        if (result['archived'] == true) archived++;
      } on CancelledException {
        rethrow;
      } catch (_) {
        errors++;
      } finally {
        task.backgroundMaintenance = null;
        maintenance.complete();
      }
    }
    final staging = Directory('$directory/staging');
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    if (_transfers == 0 && await staging.exists()) {
      await for (final entry in staging.list(followLinks: false)) {
        _lifetime.throwIfCancelled();
        if (_transfers != 0) break;
        if (entry is! Directory) continue;
        final id = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
        try { validateTaskId(id); } on FormatException { continue; }
        if (!(await entry.stat()).modified.isBefore(cutoff)) continue;
        try {
          await entry.delete(recursive: true);
          removed++;
        } on FileSystemException {
          errors++;
        }
      }
    }
    telemetry.add('maintenance_runs');
    telemetry.add('maintenance_failures', errors);
    telemetry.add('staging_directories_removed', removed);
    return {'checked_tasks': checked, 'archived_tasks': archived, 'staging_removed': removed, 'errors': errors};
  }

  void _offerSteering(_Task task, Json message) {
    final id = message['id'] as String, interrupt = message['delivery'] == 'steer';
    if (task.finishing || task.agent == null ||
        !interrupt && !task.mcpInputs.contains(id) ||
        !task.offered.add(id)) {
      return;
    }
    if (interrupt) task.codeInterrupt?.interrupt();
    withTrace(task.pendingTraces[message['id']] ?? currentTrace, () {
      task.agent!.port.send({'method': 'steer', 'params': message, '_trace': ?traceIsolateCarrier('steer')});
    });
  }

  Future<void> _discardPending(_Task task, String reason, {IsolateOwner? writer}) async {
    Future<Object?> discard(IsolateOwner owner) => callIsolate(owner.port, 'session.inbox.cancel',
      {'reason': reason}, cancellation: _lifetime);
    final discarded = writer == null ? await _withWriter(task, discard) : await discard(writer);
    task.pending.clear();
    task.pendingTraces.clear();
    task.mcpInputs.clear();
    task.offered.clear();
    if (discarded != null) _broadcast(task.id, jsonObject(discarded));
  }

  Future<String> _newTaskId(Json config, CancellationToken cancellation) async =>
      await _callNetwork('task.new_id', {'provider': config['provider']},
        cancellation: cancellation) as String;

  Future<Json> _config(Json input, {CancellationToken? cancellation}) async {
    final cwd = p.normalize(Directory(input['cwd'] as String? ?? Directory.current.path).absolute.path);
    if (!Directory(cwd).existsSync()) {
      throw ArgumentError('Working directory does not exist');
    }
    final provider = jsonObject(
      await _callNetwork('configure', input, cancellation: cancellation),
    );
    return initialConfiguration(
      {...input, ...provider, 'global_directory': directory},
      cwd,
      telemetry.enabled,
    );
  }

  void _begin(
    _Task task,
    String prompt, {
    bool compact = false,
    bool retry = false,
    Json settings = const {},
  }) {
    _lifetime.throwIfCancelled();
    if (task.disposing) throw StateError('Side chat is closing');
    if (task.busy || task.maintenance) throw StateError('Task is busy');
    if (!compact && !retry && settings['goalContinuation'] != true && prompt.isEmpty && (settings['attachments'] as List? ?? []).isEmpty) {
      throw const FormatException('Prompt is required');
    }
    if (_tasks.values.where((task) => task.busy).length >= maxAgents) {
      throw StateError('Active agent limit reached');
    }
    final effective = {...settings};
    effective['turnId'] ??= newUuidV7();
    if (!compact && !retry && settings['goalContinuation'] != true) effective['message_id'] ??= newId();
    if (effective['cwd'] != null) {
      final cwd = Directory(effective['cwd'] as String).absolute;
      if (!cwd.existsSync()) {
        throw ArgumentError('Working directory does not exist');
      }
      effective['cwd'] = p.normalize(cwd.path);
    }
    task.busy = true;
    task.protocolState['turnID'] = effective['turnId'];
    if (!task.loaded) { task.loaded = true; task.unloadDelaySecs = _threadUnloadDelaySecs; }
    task.unloadTimer?.cancel(); task.unloadTimer = null;
    task.systemError = false;
    task.retryStatus = null;
    task.finishing = false;
    task.ready = Completer<void>();
    _tasks[task.id] = task;
    task.cancelled = false;
    task.startingInputID = effective['message_id'] == null ? null : 'msg_${effective['message_id']}';
    _activity.add(activeTaskCount);
    telemetry.add('turns_started');
    final context = task.pendingTraces[settings['message_id']] ?? currentTrace;
    task.running = withTrace(context, () {
      bindTraceSession(task.id);
      return traceAsync('server.turn', () => _run(task, prompt, compact: compact, retry: retry, settings: effective),
        attributes: {'session_id': task.id, 'compact': compact});
    });
  }

  Future<void> _run(
    _Task task,
    String prompt, {
    required bool compact,
    required bool retry,
    required Json settings,
  }) async {
    Json? terminal;
    // Stop/archive/shutdown cancel the agent through its mailbox. Observe until
    // it commits its terminal event, regardless of the turn's total duration.
    final turnLifetime = CancellationToken();
    try {
      task.turnNetwork = await _acquireNetwork(turnLifetime.merge(_lifetime));
      task.turnCancellation = turnLifetime;
      if (_networkExited || !identical(network, task.turnNetwork)) {
        throw const RemoteFailure('The local chat service stopped before the turn started', code: 'network_unavailable');
      }
      task.writer ??= task.memoryStore ?? await _startStore(
        task.id,
        create: task.config != null,
        inMemory: task.config?['ephemeral'] == true,
      );
      if (task.config?['ephemeral'] == true) task.memoryStore = task.writer;
      if (task.config != null && await callIsolate(task.writer!.port, 'metadata', {'key': 'config'}) == null) {
        // Commit admission before cancellation can stop the agent's first turn.
        // An immediately archived or stopped task must still be resumable.
        final config = {...task.config!, 'task_id': task.id};
        final attachments = settings['attachments'] as List? ?? [];
        final title = prompt.trim().isNotEmpty ? prompt.trim().split('\n').first
          : attachments.firstOrNull?['name'] as String? ?? 'New session';
        final created = jsonObject(await callIsolate(task.writer!.port, 'append', {
          'type': 'task.created',
          'data': config,
          'metadata': {'config': config, 'title': title},
        }));
        _broadcast(task.id, created);
      }
      if (await callIsolate(task.writer!.port, 'metadata', {'key': 'archived_at'}) != null) {
        throw StateError('Restore this task before sending another message');
      }
      task.config ??= jsonObject(
        await callIsolate(task.writer!.port, 'metadata', {'key': 'config'}),
      );
      if (task.pending.isEmpty) {
        await callIsolate(task.writer!.port, 'session.prepare', {}, cancellation: turnLifetime);
        final inbox = await _readSession(task, 'session.inbox', {}, turnLifetime);
        task.pending.addAll((inbox['data'] as List).map(jsonObject));
      }
      final receipts = (await callIsolate(task.writer!.port, 'metadata', {'key': 'mcp_event_receipts'},
        cancellation: turnLifetime) as List? ?? []).cast<String>().toSet();
      task.mcpInputs.addAll(task.pending.map((message) => message['id'] as String).where(receipts.contains));
      if (!compact && !retry && settings['goalContinuation'] != true && !task.pending.any((message) => message['id'] == settings['message_id'])) {
        final message = <String, dynamic>{
          'id': settings['message_id'], 'prompt': prompt, 'delivery': 'steer',
          'created_at': settings['sent_at'] ?? DateTime.now().toUtc().toIso8601String(),
          if (settings['attachments'] != null) 'attachments': settings['attachments'],
          if (settings['reasoning'] != null) 'reasoning': settings['reasoning'],
        };
        final admitted = jsonObject(await callIsolate(task.writer!.port, 'append', {
          'type': 'input.pending', 'data': message,
        }, cancellation: turnLifetime));
        task.pending.add(message);
        _broadcast(task.id, admitted);
      }
      if (!compact) _startThreadName(task.id);
      for (final record in await _taskTools.prepare(task.id, task.config!['tool_interface'] as String,
        settings['cwd'] as String? ?? task.config!['cwd'] as String, task.writer!.port,
        cancellation: turnLifetime)) {
        _broadcast(task.id, record);
      }
      task.codeInterrupt = CodeInterrupt();
      task.agent = await startAgent(
        taskId: task.id,
        config: _agentConfig(task.id, task.config!),
        writer: task.writer!.port,
        network: task.turnNetwork!.port,
        clientTools: _clientTools.port,
        goals: _goalRequests.sendPort,
        taskTools: _taskTools.port,
        questions: _questions.port,
        codeInterrupt: task.codeInterrupt!.address,
      );
      task.ready!.complete();
      if (task.cancelled) {
        // Cancel after turn admission below; the mailbox preserves send order.
        scheduleMicrotask(() => callIsolate(task.agent!.port, 'cancel', {}));
      }
      final turn = callIsolate(
        task.agent!.port,
        'turn',
        {'prompt': prompt, 'compact': compact, 'retry': retry,
          'settings': {...settings, 'reasoningPinned': task.reasoningPinned}},
        timeout: null,
        cancellation: turnLifetime,
        onEvent: (event) {
          if (event['type'] == 'configuration.updated') task.reasoningPinned = true;
          if (event['type'] == 'input.committed') {
            final id = event['data']?['message_id'];
            if (task.startingInputID == 'msg_$id') task.startingInputID = null;
            task.pending.removeWhere((message) => message['id'] == id);
            final origin = task.pendingTraces.remove(id);
            if (origin != null) {
              traceInstant('session.input.committed', attributes: {
                'message_id': id, 'origin.trace_id': origin.trace,
              });
            }
            task.offered.remove(id);
            task.mcpInputs.remove(id);
          }
          if ([
            'turn.completed',
            'turn.failed',
            'turn.cancelled',
          ].contains(event['type'])) {
            terminal = event;
          } else {
            _broadcast(task.id, event);
          }
        },
      );
      if (settings['message_id'] case final String id) task.offered.add(id);
      for (final message in task.pending) {
        _offerSteering(task, message);
      }
      await turn;
    } catch (error) {
      traceError(error);
      terminal = {
        'task_id': task.id,
        'type': 'turn.failed',
        'data': {'error': error.toString()},
      };
      if (!_closing && task.writer != null) {
        try {
          terminal = jsonObject(await callIsolate(task.writer!.port, 'append', {
            'type': 'turn.failed', 'data': terminal!['data'],
          }, cancellation: turnLifetime));
        } catch (_) { /* A failed persistence owner still permits a live terminal notification. */ }
      }
    } finally {
      task.finishing = true;
      turnLifetime.cancel();
      if (!task.ready!.isCompleted) task.ready!.complete();
      if (task.writerRequests > 0) {
        await (task.writerDrained ??= Completer<void>()).future;
      }
      await task.agent?.close();
      await _taskTools.settle(task.id);
      task.codeInterrupt?.close();
      task.codeInterrupt = null;
      if (!_closing && task.writer != null && (task.cancelled || terminal?['type'] != 'turn.completed')) {
        try { await _discardPending(task, 'stopped', writer: task.writer); }
        on CancelledException { if (!_closing) rethrow; /* Shutdown preserves the remaining inbox. */ }
      }
      final retainWriter = task.loaded && !_closing;
      if (!retainWriter) await _taskTools.release(task.id);
      if (task.memoryStore == null && !retainWriter) await task.writer?.close();
      task.agent = null;
      task.turnNetwork = null;
      task.turnCancellation = null;
      if (!retainWriter) task.writer = null;
      task.busy = false;
      task.finishing = false;
      task.offered.clear();
      task.startingInputID = null;
      if (terminal != null) {
        traceInstant('server.${terminal!['type']}', attributes: {
          'status': terminal!['type'] == 'turn.completed' ? 'ok'
            : terminal!['type'] == 'turn.cancelled' ? 'cancelled' : 'error',
        });
        telemetry.add(terminal!['type'] as String);
        _broadcast(task.id, terminal!);
      }
      if (_closing) {
        // The durable inbox remains available when this session resumes.
      } else if (!task.cancelled && !task.disposing && terminal?['type'] == 'turn.completed' && task.pending.isNotEmpty) {
        final next = task.pending.first;
        try {
          _begin(
            task,
            next['prompt'] as String,
            settings: {
              'message_id': next['id'], 'sent_at': next['created_at'],
              if (next['attachments'] != null) 'attachments': next['attachments'],
              if (next['reasoning'] != null) 'reasoning': next['reasoning'],
            },
          );
        } catch (_) {
          await _discardPending(task, 'could_not_start');
        }
      }
      if (!_closing && !task.cancelled && !task.disposing && !task.busy && !task.maintenance && terminal?['type'] == 'turn.completed') {
        await _continueGoal(task.id);
      }
      _forgetIdle(task);
    }
  }

  Future<Object?> _withWriter(
    _Task task,
    Future<Object?> Function(IsolateOwner) operation, {
    bool allowShutdown = false,
    bool allowMaintenance = false,
  }) async {
    if (!allowShutdown) _lifetime.throwIfCancelled();
    if (_tasks[task.id] case final current? when !identical(current, task)) {
      throw StateError('Task ownership changed; retry the operation');
    }
    if (task.maintenance && !allowMaintenance) {
      throw StateError('Task has a pending maintenance operation');
    }
    if (task.busy || task.writer != null) {
      if (task.finishing) throw StateError('Task is finishing; retry shortly');
      final writer = task.writer;
      if (writer == null) throw StateError('Task is starting; retry shortly');
      task.writerRequests++;
      try { return await operation(writer); }
      finally {
        if (--task.writerRequests == 0) {
          task.writerDrained?.complete();
          task.writerDrained = null;
        }
      }
    }
    task.maintenance = true;
    final settled = task.maintenanceDone = Completer<void>();
    _tasks[task.id] = task;
    IsolateOwner? writer;
    try {
      writer = task.memoryStore ?? await _startStore(
        task.id,
        create: false,
      );
      return await operation(writer);
    } finally {
      try { if (task.memoryStore == null) await writer?.close(); }
      finally {
        task.maintenance = false;
        task.maintenanceDone = null;
        settled.complete();
        _forgetIdle(task);
      }
    }
  }

  void _broadcast(String taskId, Json event) {
    if ({'turn.completed', 'turn.failed', 'turn.cancelled'}.contains(event['type'])) _questions.endTurn(taskId);
    final task = _tasks[taskId];
    if (task != null) {
      if (event['type'] == 'turn.failed') task.systemError = true;
      if ({'turn.started', 'turn.completed', 'turn.failed', 'turn.cancelled'}.contains(event['type'])) _notifyThreadStatus(task);
      if (event['type'] == 'model.retrying') {
        task.retryStatus = {'type': 'retry', 'attempt': event['attempt'], 'message': event['message'],
          if (event['max_retries'] != null) 'max_retries': event['max_retries'],
          if (event['error'] != null) 'error': event['error'],
          if (event['provider_delay'] == true) 'provider_delay': true,
          'next': DateTime.now().millisecondsSinceEpoch + (event['delay_ms'] as int? ?? 0)};
      } else if ({'model.started', 'model.connected', 'text.delta', 'reasoning.delta',
        'turn.started', 'turn.completed', 'turn.failed', 'turn.cancelled'}.contains(event['type'])) {
        task.retryStatus = null;
      }
    }
    if (event['type'] == 'model.started') {
      task?.completedStreamOrdinal = 0;
      task?.streamOrdinal = 0;
      task?.streamPartType = null;
    } else if (event['type'] == 'model.retrying') {
      task?.streamOrdinal = task.completedStreamOrdinal;
      task?.streamPartType = null;
    } else if (event['type'] == 'model.output') {
      final data = jsonObject(event['data']);
      task?.completedStreamOrdinal = (data['ordinal'] as int) + (data['item']['content'] as List? ?? []).length;
      task?.streamOrdinal = task.completedStreamOrdinal;
      task?.streamPartType = null;
    }
    if (event['type'] == 'text.delta' || event['type'] == 'reasoning.delta') {
      if (task?.streamPartType != null && task?.streamPartType != event['type']) task!.streamOrdinal++;
      task?.streamPartType = event['type'] as String;
    }
    final notifications = threadNotifications(taskId, event, task?.protocolState ?? {});
    if (task != null) {
      if (event['type'] == 'turn.started') {
        task.liveItems.removeWhere((_, item) => item['type'] != 'commandExecution' || item['live'] != true);
      }
      for (final notification in notifications) {
        notification['params']['happen']['notificationSeq'] = ++task.notificationSeq;
        applyThreadNotification(task.liveItems, notification);
        if (notification['method'] == 'turn/started' || notification['method'] == 'turn/completed') {
          task.liveTurn = jsonObject(notification['params']['turn']);
        }
      }
    }
    for (final client in _clients.toList()) {
      final receivesAll = client.subscriptions.contains(taskId) || client.observations.contains(taskId) ||
        {'goal.updated', 'goal.cleared', 'task.archived', 'task.unarchived', 'thread.name.updated'}.contains(event['type']);
      for (final notification in notifications) {
        if (receivesAll || {'turn/started', 'turn/completed'}.contains(notification['method'])) {
          client.event(notification);
        }
      }
    }
    if (event['type'] == 'model.started') _tasks[taskId]?.assistantMessageID = event['data']['assistantMessageID'] as String?;
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _closeNetworkRecovery();
    _maintenanceTimer?.cancel();
    _lifetime.cancel();
    try { await _maintenance; } catch (_) { /* Shutdown still releases all owners. */ }
    _clientTools.close();
    _questions.close();
    _files.clear();
    await _terminals.close();
    for (final client in _clients.toList()) {
      client.cancellation.cancel();
      await client.attachments.close();
      if (!_networkExited) {
        await callIsolate(network.port, 'mcp.detach', {'owner': client.id});
      }
    }
    await http?.close(force: true);
    for (final task in _tasks.values) {
      task.unloadTimer?.cancel();
      task.cancelled = true;
      task.codeInterrupt?.interrupt();
      if (task.agent != null) {
        unawaited(callIsolate(task.agent!.port, 'cancel', {}));
      }
    }
    await Future.wait(
      _tasks.values.map((task) => task.running ?? Future<void>.value()),
    );
    await Future.wait(_requests.toList().map((operation) => operation.catchError((Object _) => null)));
    // Native exit watchers may still need to append their canonical completion.
    // Drain CLI ownership before closing the sole writers they report through.
    await _taskTools.close();
    await Future.wait(_tasks.values.where((task) => task.memoryStore == null && task.writer != null)
      .map((task) => task.writer!.close()));
    await Future.wait(_tasks.values.where((task) => task.memoryStore != null)
      .map((task) => task.memoryStore!.close()));
    _tasks.clear();
    _goals.clear();
    await _goalSubscription?.cancel();
    _goalRequests.close();
    unawaited(_activity.close());
    _mcpSubscriptionOwners.clear();
    unawaited(_mcpActivity.close());
    await network.close();
    if (_catalog != null) {
      try { await (await _catalog!).close(); }
      on CancelledException { /* Shutdown can cancel catalog recovery. */ }
    }
    _networkEvents.close();
    for (final client in _clients.toList()) {
      await client.close();
    }
    final path = socketPath;
    if (path != null) {
      final current = await File(path).stat();
      if (current.type == FileSystemEntityType.unixDomainSock &&
          current.changed == _socketStat?.changed &&
          current.modified == _socketStat?.modified) {
        await File(path).delete();
      }
    }
    await _socketDirectory?.delete(recursive: true);
    if (_traces != null) {
      try { await (await _traces!).close(); }
      on CancelledException { /* Shutdown can cancel recorder startup. */ }
    }
  }
}

class _Task {
  _Task(this.id, this.config);
  final String id;
  final protocolState = <String, dynamic>{};
  final liveItems = <String, Json>{};
  Json? liveTurn;
  int notificationSeq = 0;
  Json? config;
  String? sideParentID;
  IsolateOwner? memoryStore;
  Future<void>? closingSide;
  bool disposing = false;
  String? assistantMessageID;
  Json? retryStatus;
  String? startingInputID;
  int streamOrdinal = 0, completedStreamOrdinal = 0;
  String? streamPartType;
  bool busy = false, maintenance = false, cancelled = false, finishing = false;
  bool loaded = false, systemError = false;
  // Turn actors are disposable; effort is pinned for this loaded thread.
  bool reasoningPinned = false;
  int unloadDelaySecs = 60;
  Timer? unloadTimer;
  IsolateOwner? writer, agent;
  IsolateOwner? turnNetwork;
  CancellationToken? turnCancellation;
  CodeInterrupt? codeInterrupt;
  Future<void>? running;
  Completer<void>? backgroundMaintenance;
  Completer<void>? maintenanceDone, writerDrained;
  int writerRequests = 0;
  int eventAdmissions = 0;
  Completer<void>? ready;
  CancellationToken? goalContinuation;
  final pending = <Json>[];
  final pendingTraces = <String, TraceContext>{};
  final mcpInputs = <String>{};
  final offered = <String>{};
}

class _Client {
  _Client(this.socket, String directory) : local = null {
    attachments = AttachmentUploads(directory, id);
    _startWriter();
  }
  _Client.local(String directory) : socket = null, local = StreamController<Json>() {
    attachments = AttachmentUploads(directory, id);
  }
  final WebSocket? socket;
  final StreamController<Json>? local;
  final id = newId();
  final afterResponse = <Object, void Function()>{};
  late final AttachmentUploads attachments;
  final cancellation = CancellationToken();
  CancellationToken? fileSearch;
  CancellationToken? skillSearch;
  final mcpInventories = <Object, CancellationToken>{};
  final mcpLogins = <Object, CancellationToken>{};
  final sessionReads = <Object, CancellationToken>{};
  late final gitOperations = <Object, CancellationToken>{};
  final sideCreations = <Object, String>{};
  final contextSnapshots = <String, Json>{};
  final requestTraces = <Object, TraceContext>{};
  final sessionTraces = <String, TraceContext>{};
  Object? fileSearchId;
  Object? skillSearchId;
  final subscriptions = <String>{};
  // Transcript watches forward live items without retaining an execution owner.
  late final observations = <String>{};
  bool initialized = false;
  final optOutNotifications = <String>{};
  bool questions = false;
  bool mcpInputs = false;
  final _outbound = StreamController<String>();
  Future<void>? _writing, _closing;
  int _queuedBytes = 0;
  int _queuedFrames = 0, inFlight = 0;
  void _startWriter() {
    _writing = socket!.addStream(_outbound.stream.map((encoded) {
      _queuedFrames--; _queuedBytes -= utf8.encode(encoded).length;
      return encoded;
    }));
    unawaited(_writing!.then<void>((_) {}, onError: (Object _, StackTrace _) {
      cancellation.cancel(); unawaited(close());
    }));
  }
  void send(Json message) {
    final trace = message.containsKey('id') ? requestTraces.remove(message['id']) : currentTrace;
    withTrace(trace ?? currentTrace, () {
    if (currentTrace case final context? when context.session != null) sessionTraces[context.session!] = context;
    final carrier = traceSend('websocket', attributes: {
      if (message['id'] != null) 'rpc.id': message['id'],
      if (message['event'] is Map) 'event.type': message['event']['type'],
    });
    message = {...message, '_trace': ?carrier};
    if (local case final messages?) {
      if (!messages.isClosed) messages.add(jsonObject(jsonDecode(jsonEncode(message))));
    } else if (socket!.readyState == WebSocket.open && !cancellation.isCancelled) {
      final encoded = jsonEncode(message), bytes = utf8.encode(encoded).length;
      if (_queuedFrames >= 32 * 1024 || _queuedBytes + bytes > maxClientFrameBytes) {
        cancellation.cancel();
        unawaited(close(code: 1008, reason: 'Outbound queue full; reconnect and read thread history'));
        return;
      }
      _queuedFrames++; _queuedBytes += bytes; _outbound.add(encoded);
    }
    });
  }

  void event(Json event) {
    if (!initialized) return;
    final notification = event['method'] is String ? event : {'method': 'happen/event', 'params': event};
    if (!optOutNotifications.contains(notification['method'])) send(notification);
  }

  Future<void> close({int? code, String? reason}) => _closing ??= _close(code, reason);

  Future<void> _close(int? code, String? reason) async {
    cancellation.cancel();
    if (local != null) { await local!.close(); }
    else {
      await _outbound.close();
      try { await _writing; } catch (_) { /* The peer may already have disconnected. */ }
      await socket!.close(code, reason);
    }
  }
}

/// Local calls share dispatch and snapshots with desktop's WebSocket client.
class AgentClient {
  AgentClient._worker(IsolateOwner owner, ReceivePort port) : socket = null, sharedFilesystem = false {
    _worker = owner;
    _workerEvents = port;
    _subscription = port.listen((event) {
      if (event == null) { _disconnected(); return; }
      final message = jsonObject(event);
      if (message['method'] == 'connection/ready') _transportConnected = true;
      if (message['method'] == 'connection/closed') _transportConnected = false;
      if (!events.isClosed) events.add(message);
    });
    unawaited(owner.done.then((_) => _disconnected()));
  }
  AgentClient._(WebSocket connection, {required this.sharedFilesystem}) : socket = connection {
    _subscription = connection.listen(
      (raw) {
        final message = jsonObject(jsonDecode(raw as String));
        final trace = _receiveTrace(message);
        withTrace(trace, () {
        traceReceive(message['_trace'], 'websocket',
          attributes: {'bytes': utf8.encode(raw).length, 'rpc.id': message['id'],
            if (message['event'] is Map) 'event.type': message['event']['type']});
        if (message.containsKey('method')) {
          events.add({...message['method'] == 'happen/event' ? jsonObject(message['params']) : message,
            '_trace': ?trace?.carrier(local: false)});
        } else {
          final completer = _pending.remove(message['id']);
          if (message.containsKey('error')) {
            completer?.completeError(StateError(message['error'].toString()));
          } else {
            completer?.complete(message['result']);
          }
        }
        });
      },
      onDone: _disconnected,
      onError: (Object error) => _disconnected(),
    );
  }
  AgentClient.local(AgentServer server) : socket = null, sharedFilesystem = true {
    if (server._closing) throw StateError('Server is shutting down');
    _localServer = server;
    final state = _localClient = _Client.local(server.directory);
    state.initialized = true;
    server._clients.add(state);
    _subscription = state.local!.stream.listen((message) {
      final trace = _receiveTrace(message);
      withTrace(trace, () {
        traceReceive(message['_trace'], 'websocket');
        if (message['method'] is String) {
          events.add({...message['method'] == 'happen/event' ? jsonObject(message['params']) : message,
            '_trace': ?trace?.carrier(local: false)});
        }
      });
    }, onDone: _disconnected, onError: (Object _) => _disconnected());
  }
  final WebSocket? socket;
  IsolateOwner? _worker;
  ReceivePort? _workerEvents;
  AgentServer? _localServer;
  _Client? _localClient;
  bool _closed = false;
  Future<void>? _closingClient;
  final bool sharedFilesystem;
  bool get isClosed => _closed || _disconnectRecorded;
  late bool _transportConnected = false;
  bool get isConnected => !isClosed && (_worker == null || _transportConnected);
  late final StreamSubscription<dynamic> _subscription;
  final events = StreamController<Json>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  int _next = 0;
  Future<TraceStore>? _tracing;
  TraceStore? _traceStore;
  final _sessionTraces = <String, TraceContext>{};
  late final _tracedSessions = <String>{};
  bool _disconnectRecorded = false;
  late final _connectionDone = Completer<void>();
  final _traceLifetime = CancellationToken();
  Future<TraceStore> startTracing(String directory) => _tracing ??=
    TraceStore.open('$directory/telemetry-desktop.sqlite', cancellation: _traceLifetime)
      .then((store) => _traceStore = store);
  void traceSession(String sessionID) {
    final store = _traceStore;
    if (store == null) throw StateError('Start the trace recorder before enabling a session');
    _tracedSessions.add(sessionID);
    _sessionTraces.putIfAbsent(sessionID,
      () => TraceContext(sink: store.sink, service: 'desktop', session: sessionID));
  }
  TraceContext? _receiveTrace(Json message) {
    final context = _traceStore == null ? null
      : traceContextFrom(message['_trace'], sink: _traceStore!.sink, service: 'desktop');
    if (context?.session case final session?) _sessionTraces[session] = context!;
    return context;
  }
  TraceContext? eventTrace(Json event) => _receiveTrace(event);

  Future<Json> tracePage(String sessionID, {int after = 0, int? through,
    required CancellationToken cancellation}) async => jsonObject(await withTrace(null, () => _requestUntraced(
      'session.trace.page', {'sessionID': sessionID, 'after': after, 'through': through},
      cancellation: cancellation)));
  Future<Json> traceStatus(String sessionID, {required CancellationToken cancellation}) async =>
    jsonObject(await withTrace(null, () => _requestUntraced('session.trace.status', {'sessionID': sessionID}, cancellation: cancellation)));

  static Future<AgentClient> connect(
    Uri uri, {
    String? token,
    bool? sharedFilesystem,
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
    final lifetime = cancellation == null
        ? deadline
        : cancellation.merge(deadline);
    final http = HttpClient();
    final hook = CancellationHook(lifetime, () => http.close(force: true));
    try {
      if (uri.scheme == 'unix') {
        if (uri.path.isEmpty || !uri.path.startsWith('/')) {
          throw ArgumentError('Unix socket address must be absolute');
        }
        http.findProxy = (_) => 'DIRECT';
        http.connectionFactory = (_, _, _) => Socket.startConnect(
          InternetAddress(uri.path, type: InternetAddressType.unix),
          0,
        );
      }
      final socket = await WebSocket.connect(
        uri.scheme == 'unix' ? 'ws://localhost/ws' : uri.toString(),
        compression: CompressionOptions.compressionOff,
        customClient: http,
        headers: token == null ? null : {'Authorization': 'Bearer $token'},
      ).asCancellable(lifetime);
      if (lifetime.isCancelled) {
        await socket.close();
        lifetime.throwIfCancelled();
      }
      socket.pingInterval = const Duration(seconds: 60);
      final client = AgentClient._(socket, sharedFilesystem: sharedFilesystem ?? uri.scheme == 'unix');
      try {
        await client._request('initialize', {'clientInfo': {'name': 'happen', 'version': '0.1.0'},
          'capabilities': {'experimentalApi': true}}, cancellation: lifetime);
        socket.add(jsonEncode({'method': 'initialized'}));
        return client;
      } catch (_) { await client.close(); rethrow; }
    } finally {
      hook.dispose();
      deadline.cancel();
      http.close();
    }
  }

  Future<Object?> request(String method, [Json params = const {}]) => _request(method, params);

  Future<Json> inspectWorkspace(String path, {required CancellationToken cancellation}) async =>
    jsonObject(await _request('workspace.inspect', {'path': path}, cancellation: cancellation));

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
    if (!{'session.context', 'thread/resume', 'thread/read', 'thread/items/list', 'thread/turns/list', 'thread/list', 'thread/image/read'}.contains(method)) {
      throw ArgumentError('Unknown session read');
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



  Future<Json> uploadAttachment(String path, {required String name, required String type,
    required CancellationToken cancellation, void Function(int sent, int total)? onProgress}) async {
    cancellation.throwIfCancelled();
    final id = newId();
    var complete = false;
    final file = File(path);
    final size = await file.length();
    cancellation.throwIfCancelled();
    try {
      await _request('attachments.begin', {'upload_id': id, 'name': name, 'type': type, 'size': size}, cancellation: cancellation);
      var sent = 0;
      final block = BytesBuilder(copy: false);
      Future<void> append() async {
        cancellation.throwIfCancelled();
        final bytes = block.takeBytes();
        await _request('attachments.append', {'upload_id': id, 'offset': sent, 'data': base64Encode(bytes)}, cancellation: cancellation);
        sent += bytes.length;
        onProgress?.call(sent, size);
      }
      final input = ownStream(file.openRead(), cancellation);
      try {
        await for (final chunk in input.stream) {
          cancellation.throwIfCancelled();
          for (var offset = 0; offset < chunk.length;) {
            final end = (offset + maxAttachmentChunkBytes - block.length).clamp(0, chunk.length);
            block.add(chunk.sublist(offset, end));
            offset = end;
            if (block.length == maxAttachmentChunkBytes) await append();
          }
        }
        if (block.isNotEmpty) await append();
      } finally { await input.close(); }
      final result = jsonObject(await _request('attachments.finish', {'upload_id': id}, cancellation: cancellation));
      complete = true;
      return result;
    } finally {
      if (!complete) await discardAttachment(id);
    }
  }

  Future<void> discardAttachment(String id) async {
    if (_closed || socket != null && socket!.readyState != WebSocket.open) return;
    try {
      await _request('attachments.cancel', {'upload_id': id}, timeout: const Duration(seconds: 10));
    } catch (_) { /* Disconnect and server maintenance also release partial uploads. */ }
  }

  Future<Json> searchFiles(String cwd, String query, {required CancellationToken cancellation}) async =>
      jsonObject(await _request('files.search', {'cwd': cwd, 'query': query},
          cancellation: cancellation, timeout: const Duration(seconds: 10)));

  Future<Json> searchSkills(String cwd, String query, {String? provider, required CancellationToken cancellation}) async =>
      jsonObject(await _request('skills.search', {'cwd': cwd, 'query': query, 'provider': ?provider},
          cancellation: cancellation, timeout: const Duration(seconds: 10)));

  Future<Json> mcpInventory({bool verbose = false, String? server, String? cwd, required CancellationToken cancellation}) async =>
      jsonObject(await _request('mcp.inventory', {'verbose': verbose, 'server': ?server, 'cwd': ?cwd},
        cancellation: cancellation, timeout: const Duration(seconds: 35)));

  Future<Json> mcpLogin(String server, String loginId, {String? cwd, required CancellationToken cancellation}) async =>
      jsonObject(await _request('mcp.auth.login', {'server': server, 'login_id': loginId, 'cwd': ?cwd},
        cancellation: cancellation, timeout: const Duration(minutes: 6)));

  Future<void> mcpLogout(String server, {String? cwd, required CancellationToken cancellation}) async =>
      _request('mcp.auth.logout', {'server': server, 'cwd': ?cwd}, cancellation: cancellation);

  Future<Json> desktopAuthorization({bool refresh = false, required CancellationToken cancellation}) async =>
      jsonObject(await _request('auth.desktop', {'refresh': refresh}, cancellation: cancellation,
        timeout: const Duration(seconds: 30)));

  Future<Object?> _request(String method, Json params, {
    CancellationToken? cancellation,
    Duration timeout = const Duration(minutes: 5),
  }) {
    final store = _traceStore;
    final forking = {'session.side.create', 'thread/fork'}.contains(method);
    final session = (params['threadId'] ?? params['sessionID'] ?? params['task_id']) as String?;
    final parent = currentTrace;
    final inherited = session == null || parent?.session == null || parent?.session == session ? parent : null;
    final context = {'session.create', 'task.start'}.contains(method) && params['tracing'] != true ? null
      : inherited != null && (!forking || inherited.session == null) ? inherited
      : store == null || !_tracedSessions.contains(session) ? null : TraceContext(sink: store.sink,
          service: 'desktop', session: forking ? null : session);
    if (context?.session case final session?) _sessionTraces[session] = context!;
    return withTrace(context, () => traceAsync('desktop.$method',
      () => _requestUntraced(method, params, cancellation: cancellation, timeout: timeout),
      category: 'websocket', attributes: {
        if (forking) 'parent.session_id': session,
      }));
  }

  Future<Object?> _requestUntraced(String method, Json params, {
    CancellationToken? cancellation,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    cancellation?.throwIfCancelled();
    if (_closed || socket != null && socket!.readyState != WebSocket.open) {
      throw StateError('Connection is closed');
    }
    if (_worker case final worker?) {
      return callIsolate(worker.port, 'request', {'method': method, 'params': params, 'timeout': timeout.inMilliseconds},
        cancellation: cancellation, timeout: timeout);
    }
    if (_localServer case final server?) {
      final state = _localClient!;
      if (state.cancellation.isCancelled) throw StateError('Connection is closed');
      if (state.inFlight >= 32) throw StateError('Too many outstanding requests');
      final id = ++_next;
      final deadline = TimeoutCancellationToken(timeout);
      final token = cancellation == null ? deadline : cancellation.merge(deadline);
      final hook = CancellationHook(token, () {
        state.sessionReads[id]?.cancel();
        state.gitOperations[id]?.cancel();
        if (method == 'session.side.create') {
          if (server._tasks[state.sideCreations[id]] case final side?) unawaited(server._closeSide(side));
        }
        if (method == 'files.search') state.fileSearch?.cancel();
        if (method == 'skills.search') state.skillSearch?.cancel();
        state.mcpInventories[id]?.cancel();
        state.mcpLogins[id]?.cancel();
      });
      state.inFlight++;
      final carrier = traceSend('websocket', attributes: {'rpc.method': method, 'rpc.id': id});
      final operation = () async {
        try {
          return await server._dispatch(method, jsonObject(jsonDecode(jsonEncode(params))), state, id, trace: carrier);
        } finally {
          final response = withTrace(state.requestTraces.remove(id),
            () => traceSend('websocket', attributes: {'rpc.id': id, 'transport': 'local'}));
          withTrace(_receiveTrace({'_trace': response}),
            () => traceReceive(response, 'websocket', attributes: {'rpc.id': id, 'transport': 'local'}));
        }
      }();
      server._requests.add(operation);
      unawaited(operation.then((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(() {
        server._requests.remove(operation);
        state.inFlight--;
      }));
      try {
        final result = await operation.asCancellable(token.merge(state.cancellation));
        if (state.afterResponse.remove(id) case final effect?) Timer.run(effect);
        return jsonDecode(jsonEncode(result));
      } finally { state.afterResponse.remove(id); hook.dispose(); deadline.cancel(); }
    }
    final id = ++_next;
    final deadline = TimeoutCancellationToken(timeout);
    final token = cancellation == null ? deadline : cancellation.merge(deadline);
    final result = CancellableCompleter<Object?>(token, onCancel: () {
      _pending.remove(id);
      if (_closed) return;
      if (method.startsWith('git/') && socket!.readyState == WebSocket.open) {
        socket!.add(jsonEncode({'method': 'git/cancel', 'params': {'requestId': id}}));
      }
      if ((method.startsWith('terminal/') || {'thread/resume', 'thread/read', 'thread/list', 'thread/items/list', 'thread/turns/list', 'session.context', 'session.trace.page', 'session.trace.status',
        'session.side.create', 'workspace.inspect', 'workspace.discover'}.contains(method)) && socket!.readyState == WebSocket.open) {
        socket!.add(jsonEncode({'method': 'session.read.cancel', 'params': {'request_id': id}}));
      }
      if (method == 'files.search' && socket!.readyState == WebSocket.open) {
        socket!.add(jsonEncode({'method': 'files.cancel', 'params': {'request_id': id}}));
      }
      if (method == 'skills.search' && socket!.readyState == WebSocket.open) {
        socket!.add(jsonEncode({'method': 'skills.cancel', 'params': {'request_id': id}}));
      }
      if (method == 'mcp.inventory' && socket!.readyState == WebSocket.open) {
        socket!.add(jsonEncode({'method': 'mcp.inventory.cancel', 'params': {'request_id': id}}));
      }
      if ((method == 'mcp.auth.login' || method == 'mcp.auth.logout') && socket!.readyState == WebSocket.open) {
        socket!.add(jsonEncode({'method': 'mcp.auth.login.cancel', 'params': {'request_id': id}}));
      }
    });
    _pending[id] = result;
    socket!.add(jsonEncode({'id': id, 'method': method, 'params': params,
      '_trace': ?traceSend('websocket', attributes: {'rpc.method': method, 'rpc.id': id})}));
    try {
      return await result.future;
    } finally {
      _pending.remove(id);
      deadline.cancel();
    }
  }

  void _disconnected() {
    if (_disconnectRecorded) return;
    _disconnectRecorded = true;
    if (!_connectionDone.isCompleted) _connectionDone.complete();
    for (final context in _sessionTraces.values) {
      if (!_tracedSessions.contains(context.session)) continue;
      withTrace(context, () => traceInstant('websocket.disconnected', category: 'websocket',
        attributes: {'pending_requests': _pending.length, 'close.code': socket?.closeCode}));
    }
    for (final completer in _pending.values) {
      completer.completeError(StateError('Connection closed'));
    }
    _pending.clear();
    if (!events.isClosed) unawaited(events.close());
  }

  Future<void> close() => _closingClient ??= _closeClient();
  Future<void> _closeClient() async {
    _closed = true;
    try {
      if (_localClient case final state?) {
        _localServer!._detach(state);
        await state.close();
      } else if (_worker case final worker?) {
        try { await worker.close(); }
        finally { _workerEvents?.close(); }
      } else {
        await socket!.close();
        // Keep reading until the peer's close frame (or the WebSocket's bounded
        // close timeout). Cancelling first strands its close-handshake timer.
        await _connectionDone.future;
      }
    } finally {
      await _subscription.cancel();
      _disconnected();
      _traceLifetime.cancel();
      if (_tracing != null) {
        try { await (await _tracing!).close(); }
        on CancelledException { /* Shutdown can cancel recorder startup. */ }
      }
    }
  }
}

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
