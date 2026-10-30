import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent/agent.dart';
import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

import 'src/network.dart';
import 'src/client_tools.dart';

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
  final HttpServer http;
  final IsolateOwner network;
  final String? token;
  final int maxAgents;
  final Telemetry telemetry;
  final ReceivePort _networkEvents;
  final _lifetime = CancellationToken();
  final _clientTools = ClientToolBridge();
  String? socketPath;
  Directory? _socketDirectory;
  FileStat? _socketStat;
  final _clients = <_Client>{};
  final _tasks = <String, _Task>{};
  bool _closing = false;
  bool _networkExited = false;

  static Future<AgentServer> start({
    required String directory,
    String host = '127.0.0.1',
    int port = 8765,
    String? token,
    String? endpoint,
    String? socketPath,
    int maxAgents = 256,
    bool telemetry = true,
  }) async {
    final address = InternetAddress.tryParse(host);
    if (socketPath == null &&
        (address == null || !address.isLoopback) &&
        (token == null || token.isEmpty)) {
      throw ArgumentError(
        'A bearer token is required for a non-loopback listener',
      );
    }
    if (maxAgents < 1 || maxAgents > 1024)
      throw ArgumentError('maxAgents must be 1..1024');
    await Directory(directory).create(recursive: true);
    if (socketPath != null) {
      socketPath = File(socketPath).absolute.path;
      if (await FileSystemEntity.type(socketPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException('Socket path already exists', socketPath);
      }
    }
    final events = ReceivePort();
    final network = await startNetwork(
      directory,
      endpoint: endpoint,
      events: events.sendPort,
    );
    try {
      final http = await HttpServer.bind(
        socketPath == null
            ? host
            : InternetAddress(socketPath, type: InternetAddressType.unix),
        socketPath == null ? port : 0,
      );
      if (socketPath != null) {
        final permissions = await Process.run('chmod', ['600', socketPath]);
        if (permissions.exitCode != 0) {
          await http.close(force: true);
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
      if (socketPath != null)
        server._socketStat = await File(socketPath).stat();
      events.listen((raw) {
        final message = jsonObject(raw);
        for (final client in server._clients.where(
          (client) => client.id == message['owner'],
        )) {
          client.event(jsonObject(message['event']));
        }
      });
      unawaited(
        network.done.then((_) {
          server._networkExited = true;
          if (!server._closing) {
            for (final task in server._tasks.values) {
              final agent = task.agent;
              if (agent != null)
                agent.port.send({'method': 'cancel', 'params': {}});
            }
          }
        }),
      );
      http.listen(server._accept);
      return server;
    } catch (_) {
      events.close();
      await network.close();
      rethrow;
    }
  }

  /// Embedding keeps the client and server in one process, using UDS for the API.
  static Future<AgentServer> startEmbedded({
    required String directory,
    String? endpoint,
    bool telemetry = true,
  }) async {
    final sockets = await Directory.systemTemp.createTemp('happen-');
    try {
      final permissions = await Process.run('chmod', ['700', sockets.path]);
      if (permissions.exitCode != 0)
        throw StateError('Could not restrict socket directory permissions');
      final server = await start(
        directory: directory,
        socketPath: '${sockets.path}/s',
        endpoint: endpoint,
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
          host: http.address.address,
          port: http.port,
          path: '/ws',
        );

  Future<void> _accept(HttpRequest request) async {
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
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    socket.pingInterval = const Duration(seconds: 30);
    final client = _Client(socket);
    _clients.add(client);
    socket.listen(
      (raw) async {
        Object? id;
        try {
          if (raw is! String || utf8.encode(raw).length > maxFrameBytes)
            throw const FormatException('Invalid or oversized frame');
          final request = jsonObject(jsonDecode(raw));
          id = request['id'];
          if (request['method'] == null &&
              request.containsKey('id') &&
              (request.containsKey('result') || request.containsKey('error'))) {
            _clientTools.complete(client.id, request);
            return;
          }
          if (request['method'] == 'events.ack') {
            client.credits =
                (client.credits +
                        ((request['params']?['count'] as int?) ?? 1).clamp(
                          0,
                          256,
                        ))
                    .clamp(0, 256);
            return;
          }
          if (id == null) throw const FormatException('Request ID is required');
          if (client.inFlight >= 32)
            throw StateError('Too many outstanding requests');
          client.inFlight++;
          try {
            final result = await _dispatch(
              requiredString(request, 'method'),
              jsonObject(request['params'] ?? {}),
              client,
            );
            client.send({'id': id, 'result': result});
          } finally {
            client.inFlight--;
          }
        } catch (error) {
          client.send({
            'id': id,
            'error': {'message': error.toString()},
          });
        }
      },
      onDone: () => _detach(client),
      onError: (Object _) => _detach(client),
    );
  }

  void _detach(_Client client) {
    if (!_clients.remove(client)) return;
    client.cancellation.cancel();
    _clientTools.detach(client.id);
    if (!_networkExited)
      unawaited(
        callIsolate(network.port, 'mcp.detach', {
          'owner': client.id,
        }).catchError((Object _) => null),
      );
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
        await callIsolate(network.port, 'mcp.webhook', {
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

  Future<Object?> _dispatch(String method, Json params, _Client client) async {
    if (_closing) throw StateError('Server is shutting down');
    if (method.startsWith('mcp.')) {
      if (!{
        'mcp.status',
        'mcp.reload',
        'mcp.request',
        'mcp.events.subscribe',
        'mcp.events.unsubscribe',
        'mcp.events.subscriptions',
      }.contains(method)) {
        throw ArgumentError('Unknown MCP client operation');
      }
      return callIsolate(network.port, method, {
        ...params,
        'owner': client.id,
      }, cancellation: client.cancellation);
    }
    switch (method) {
      case 'ping':
        return {'version': '0.1.0'};
      case 'telemetry':
        return {
          'active_tasks': _tasks.values.where((task) => task.busy).length,
          'rss_bytes': ProcessInfo.currentRss,
          ...telemetry.snapshot(),
        };
      case 'task.start':
        final id = newId();
        final config = await _config(params);
        if (params['client_tools'] != null) {
          _clientTools.register(
            id,
            client.id,
            params['client_tools'],
            client.send,
          );
        }
        final task = _tasks[id] = _Task(id, config);
        client.subscriptions.add(id);
        _begin(task, requiredString(params, 'prompt'), settings: params);
        return {'task_id': id};
      case 'history.import':
        final targetDirectory = directory;
        final source = requiredString(params, 'path');
        final operationId = params['operation_id'] as String?;
        final id = await Isolate.run(
          () => TaskStore.importFrom(
            targetDirectory,
            source,
            operationId: operationId,
          ),
        );
        return {'task_id': id};
      default:
        final id = requiredString(params, 'task_id');
        validateTaskId(id);
        client.subscriptions.add(id);
        final task = _tasks.putIfAbsent(id, () => _Task(id, null));
        if (method == 'tools.register') {
          return _clientTools.register(
            id,
            client.id,
            params['tools'],
            client.send,
          );
        }
        if (method == 'task.subscribe') return {'task_id': id};
        if (method == 'task.cancel') {
          task.cancelled = true;
          final agent = task.agent;
          if (agent != null) await callIsolate(agent.port, 'cancel', {});
          return null;
        }
        if (method == 'task.send' || method == 'task.compact') {
          _begin(
            task,
            params['prompt'] as String? ?? '',
            compact: method == 'task.compact',
            settings: params,
          );
          return {'task_id': id};
        }
        if (method == 'history.page') {
          return _withWriter(
            task,
            (writer) => callIsolate(writer.port, 'history', {
              'after': params['after'] ?? 0,
              'limit': params['limit'] ?? 100,
            }),
          );
        }
        if (method == 'history.export') {
          if (task.busy) throw StateError('Export requires an idle task');
          return _withWriter(
            task,
            (writer) => callIsolate(writer.port, 'export', {
              'path': requiredString(params, 'path'),
            }),
          );
        }
        if (method == 'task.fork') {
          final child = newId();
          await _withWriter(
            task,
            (writer) => callIsolate(writer.port, 'fork', {
              'id': child,
              'through': params['through'],
            }),
          );
          return {'task_id': child};
        }
        throw StateError('Unknown method: $method');
    }
  }

  Future<Json> _config(Json input) async {
    final cwd = Directory(input['cwd'] as String? ?? Directory.current.path)
        .absolute
        .path;
    if (!Directory(cwd).existsSync())
      throw ArgumentError('Working directory does not exist');
    final provider = jsonObject(
      await callIsolate(network.port, 'configure', input),
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
    Json settings = const {},
  }) {
    if (_networkExited)
      throw StateError(
        'Network worker exited; restart the server before starting a turn',
      );
    if (task.busy || task.maintenance) throw StateError('Task is busy');
    if (!compact && prompt.isEmpty)
      throw const FormatException('Prompt is required');
    if (_tasks.values.where((task) => task.busy).length >= maxAgents)
      throw StateError('Active agent limit reached');
    final effective = {...settings};
    if (effective['cwd'] != null) {
      final cwd = Directory(effective['cwd'] as String).absolute;
      if (!cwd.existsSync())
        throw ArgumentError('Working directory does not exist');
      effective['cwd'] = cwd.path;
    }
    task.busy = true;
    task.cancelled = false;
    telemetry.add('turns_started');
    task.running = _run(task, prompt, compact: compact, settings: effective);
  }

  Future<void> _run(
    _Task task,
    String prompt, {
    required bool compact,
    required Json settings,
  }) async {
    Json? terminal;
    try {
      task.writer = await startStore(
        directory,
        task.id,
        create: task.config != null,
        legacyDecoder: gptItemFromNative,
      );
      task.config ??= jsonObject(
        await callIsolate(task.writer!.port, 'metadata', {'key': 'config'}),
      );
      if (task.config!['provider_settings'] == null) {
        final legacy = task.config!;
        final selected = jsonObject(
          await callIsolate(network.port, 'configure', {
            'provider': 'gpt',
            'model': legacy['model'],
            'reasoning': legacy['reasoning'],
          }),
        );
        task.config = {
          ...legacy,
          ...selected,
          'instructions': legacy['instructions'],
          'tools': gptToolsFromNative((legacy['tools'] as List).map(jsonObject))
              .map((v) => v.toJson())
              .toList(),
          'global_directory': directory,
        };
        await callIsolate(task.writer!.port, 'append', {
          'type': 'task.configuration_migrated',
          'data': task.config,
          'metadata': {'config': task.config},
        });
      }
      task.agent = await startAgent(
        taskId: task.id,
        config: task.config!,
        writer: task.writer!.port,
        network: network.port,
        clientTools: _clientTools.port,
      );
      if (task.cancelled) {
        // Cancel after turn admission below; the mailbox preserves send order.
        scheduleMicrotask(() => callIsolate(task.agent!.port, 'cancel', {}));
      }
      await callIsolate(
        task.agent!.port,
        'turn',
        {'prompt': prompt, 'compact': compact, 'settings': settings},
        onEvent: (event) {
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
    } catch (error) {
      terminal = {
        'task_id': task.id,
        'type': 'turn.failed',
        'data': {'error': error.toString()},
      };
    } finally {
      await task.agent?.close();
      await task.writer?.close();
      task.agent = null;
      task.writer = null;
      task.busy = false;
      if (terminal != null) {
        telemetry.add(terminal!['type'] as String);
        _broadcast(task.id, terminal!);
      }
    }
  }

  Future<Object?> _withWriter(
    _Task task,
    Future<Object?> Function(IsolateOwner) operation,
  ) async {
    if (task.maintenance)
      throw StateError('Task has a pending maintenance operation');
    if (task.busy) {
      final writer = task.writer;
      if (writer == null) throw StateError('Task is starting; retry shortly');
      return operation(writer);
    }
    task.maintenance = true;
    IsolateOwner? writer;
    try {
      writer = await startStore(
        directory,
        task.id,
        create: false,
        legacyDecoder: gptItemFromNative,
      );
      return await operation(writer);
    } finally {
      await writer?.close();
      task.maintenance = false;
    }
  }

  void _broadcast(String taskId, Json event) {
    for (final client in _clients.toList()) {
      if (client.subscriptions.contains(taskId)) client.event(event);
    }
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _lifetime.cancel();
    _clientTools.close();
    for (final client in _clients.toList()) {
      client.cancellation.cancel();
      if (!_networkExited)
        await callIsolate(network.port, 'mcp.detach', {'owner': client.id});
    }
    await http.close(force: true);
    for (final task in _tasks.values) {
      task.cancelled = true;
      if (task.agent != null)
        unawaited(callIsolate(task.agent!.port, 'cancel', {}));
    }
    await Future.wait(
      _tasks.values.map((task) => task.running ?? Future<void>.value()),
    );
    await network.close();
    _networkEvents.close();
    for (final client in _clients.toList()) {
      await client.socket.close();
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
  }
}

class _Task {
  _Task(this.id, this.config);
  final String id;
  Json? config;
  bool busy = false, maintenance = false, cancelled = false;
  IsolateOwner? writer, agent;
  Future<void>? running;
}

class _Client {
  _Client(this.socket);
  final WebSocket socket;
  final id = newId();
  final cancellation = CancellationToken();
  final subscriptions = <String>{};
  int credits = 256, inFlight = 0;
  void send(Json message) {
    if (socket.readyState == WebSocket.open) socket.add(jsonEncode(message));
  }

  void event(Json event) {
    if (credits-- <= 0) {
      unawaited(
        socket.close(
          1008,
          'Event backlog exceeded; reconnect and page committed history',
        ),
      );
      return;
    }
    send({'event': event});
  }
}

/// The CLI uses the same multiplexed WebSocket protocol as other clients.
class AgentClient {
  AgentClient._(this.socket) {
    _subscription = socket.listen(
      (raw) {
        final message = jsonObject(jsonDecode(raw as String));
        if (message.containsKey('event')) {
          events.add(jsonObject(message['event']));
          socket.add(
            jsonEncode({
              'method': 'events.ack',
              'params': {'count': 1},
            }),
          );
        } else {
          final completer = _pending.remove(message['id']);
          if (message.containsKey('error')) {
            completer?.completeError(StateError(message['error'].toString()));
          } else {
            completer?.complete(message['result']);
          }
        }
      },
      onDone: _disconnected,
      onError: (Object error) => _disconnected(),
    );
  }
  final WebSocket socket;
  late final StreamSubscription<dynamic> _subscription;
  final events = StreamController<Json>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  int _next = 0;

  static Future<AgentClient> connect(
    Uri uri, {
    String? token,
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
        if (uri.path.isEmpty || !uri.path.startsWith('/'))
          throw ArgumentError('Unix socket address must be absolute');
        http.findProxy = (_) => 'DIRECT';
        http.connectionFactory = (_, _, _) => Socket.startConnect(
          InternetAddress(uri.path, type: InternetAddressType.unix),
          0,
        );
      }
      final socket = await WebSocket.connect(
        uri.scheme == 'unix' ? 'ws://localhost/ws' : uri.toString(),
        customClient: http,
        headers: token == null ? null : {'Authorization': 'Bearer $token'},
      ).asCancellable(lifetime);
      if (lifetime.isCancelled) {
        await socket.close();
        lifetime.throwIfCancelled();
      }
      return AgentClient._(socket);
    } finally {
      hook.dispose();
      deadline.cancel();
      http.close();
    }
  }

  Future<Object?> request(String method, [Json params = const {}]) async {
    if (socket.readyState != WebSocket.open)
      throw StateError('Connection is closed');
    final id = ++_next, result = Completer<Object?>();
    _pending[id] = result;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    try {
      return await result.future.timeout(const Duration(minutes: 5));
    } finally {
      _pending.remove(id);
    }
  }

  void _disconnected() {
    for (final completer in _pending.values) {
      completer.completeError(StateError('Connection closed'));
    }
    _pending.clear();
    if (!events.isClosed) unawaited(events.close());
  }

  Future<void> close() async {
    await socket.close();
    await _subscription.cancel();
    _disconnected();
  }
}
