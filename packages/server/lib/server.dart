import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:agent/agent.dart';
import 'package:ai/ai.dart';
import 'package:code_mode/code_mode.dart';
import 'package:protocol/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

import 'src/network.dart';
import 'src/client_tools.dart';
import 'src/task_tools.dart';
import 'src/file_search.dart';
import 'src/attachments.dart';

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
  final IsolateOwner network;
  final String? token;
  final int maxAgents;
  final Telemetry telemetry;
  final ReceivePort _networkEvents;
  final _lifetime = CancellationToken();
  final _clientTools = ClientToolBridge();
  final _taskTools = TaskToolBridge();
  final _files = FileSearch();
  String? socketPath;
  Directory? _socketDirectory;
  FileStat? _socketStat;
  final _clients = <_Client>{};
  final _tasks = <String, _Task>{};
  final _activity = StreamController<int>.broadcast();
  final _requests = <Future<Object?>>{};
  final _imports = <String, Future<String>>{};
  bool _closing = false;
  bool _networkExited = false;
  Timer? _maintenanceTimer;
  Future<Json>? _maintenance;
  int _transfers = 0;

  /// Activity belongs to this server instance, independent of client subscriptions.
  int get activeTaskCount => _tasks.values.where((task) => task.busy).length;
  Stream<int> get activeTaskCounts => _activity.stream;

  static Future<AgentServer> start({
    required String directory,
    String host = '127.0.0.1',
    int port = 8765,
    String? token,
    String? endpoint,
    String? apiKeyEnv,
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
    await Directory(directory).create(recursive: true);
    if (socketPath != null) {
      socketPath = File(socketPath).absolute.path;
      if (await FileSystemEntity.type(socketPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException('Socket path already exists', socketPath);
      }
    }
    final events = ReceivePort();
    final IsolateOwner network;
    try {
      network = await startNetwork(
        directory,
        endpoint: endpoint,
        apiKeyEnv: apiKeyEnv,
        configPath: configPath,
        skillsHome: skillsHome,
        events: events.sendPort,
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
      if (socketPath != null) {
        server._socketStat = await File(socketPath).stat();
      }
      events.listen((raw) {
        final message = jsonObject(raw);
        for (final client in server._clients.where(
          (client) => message['owner'] == null || client.id == message['owner'],
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
              if (agent != null) {
                task.codeInterrupt?.interrupt();
                agent.port.send({'method': 'cancel', 'params': {}});
              }
            }
          }
        }),
      );
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
    String? configPath,
    String? skillsHome,
    bool telemetry = true,
  }) => start(directory: directory, endpoint: endpoint, apiKeyEnv: apiKeyEnv, configPath: configPath,
    skillsHome: skillsHome, telemetry: telemetry, inProcess: true);

  /// One process, using UDS on Unix and authenticated loopback on Windows.
  static Future<AgentServer> startEmbedded({
    required String directory,
    String? endpoint,
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
    final socket = await WebSocketTransformer.upgrade(request,
      compression: CompressionOptions.compressionOff);
    socket.pingInterval = const Duration(seconds: 30);
    final client = _Client(socket, directory);
    _clients.add(client);
    socket.listen(
      (raw) async {
        Object? id;
        try {
          if (raw is! String || utf8.encode(raw).length > maxClientFrameBytes) {
            throw const FormatException('Invalid or oversized frame');
          }
          final request = jsonObject(jsonDecode(raw));
          id = request['id'];
          if (request['method'] == null &&
              request.containsKey('id') &&
              (request.containsKey('result') || request.containsKey('error'))) {
            _clientTools.complete(client.id, request);
            return;
          }
          if (request['method'] == 'events.ack') {
            client.acknowledge(((request['params']?['count'] as int?) ?? 1).clamp(0, 256));
            return;
          }
          if (request['method'] == 'files.cancel') {
            if (request['params']?['request_id'] == client.fileSearchId) {
              client.fileSearch?.cancel();
            }
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
          if (id == null) throw const FormatException('Request ID is required');
          if (client.inFlight >= 32) {
            throw StateError('Too many outstanding requests');
          }
          client.inFlight++;
          Future<Object?>? operation;
          try {
            operation = _dispatch(
              requiredString(request, 'method'),
              jsonObject(request['params'] ?? {}),
              client,
              id,
            );
            _requests.add(operation);
            final result = await operation;
            client.send({'id': id, 'result': result});
          } finally {
            _requests.remove(operation);
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

  Future<Object?> _dispatch(String method, Json params, _Client client, Object requestId) async {
    _lifetime.throwIfCancelled();
    if (_closing) throw StateError('Server is shutting down');
    if (method == 'session.read.cancel') {
      client.sessionReads[params['request_id']]?.cancel();
      return null;
    }
    final receivedAt = DateTime.now().toUtc().toIso8601String();
    final identityKey = method.startsWith('session.') ? 'sessionID' : 'task_id';
    if (method.startsWith('session.') && params['sessionID'] is String) {
      params = {...params, 'task_id': params['sessionID']}..remove('sessionID');
    }
    if (method.startsWith('session.')) client.sessionProtocol = true;
    method = const {
      'session.create': 'task.start', 'session.prompt': 'task.send',
      'session.interrupt': 'task.cancel', 'session.compact': 'task.compact',
      'session.archive': 'task.archive', 'session.unarchive': 'task.unarchive',
      'session.fork': 'task.fork',
      'session.hibernate': 'task.hibernate', 'session.subscribe': 'task.subscribe',
    }[method] ?? method;
    if (method.startsWith('attachments.')) return client.attachments.handle(method, params);
    if (method == 'task.start' || method == 'task.send') {
      final claimed = await client.attachments.claim(params['attachments']);
      var committed = false;
      try {
      final prompt = params['prompt'] ?? '';
      if (prompt is! String) throw const FormatException('Prompt must be text');
      final envelope = {...params}..remove('attachments');
      final attachments = await prepareInputAttachments(claimed.parts,
        cancellation: client.cancellation,
        envelopeBytes: utf8.encode(jsonEncode({'id': requestId, 'method': method, 'params': envelope})).length);
      validateUserInput(prompt, attachments);
      params = {...params, 'prompt': prompt, if (attachments.isNotEmpty) 'attachments': attachments};
      client.cancellation.throwIfCancelled();
      final result = await _dispatchPrepared(method, params, client, requestId, receivedAt, identityKey);
      committed = true;
      return result;
      } finally {
        await client.attachments.release(claimed.ids, committed: committed);
      }
    }
    if ({'session.message.list', 'session.context', 'session.event.list'}.contains(method)) {
      final operation = CancellationToken();
      client.sessionReads[requestId] = operation;
      try { return await _dispatchPrepared(method, params, client, requestId, receivedAt, identityKey); }
      finally { client.sessionReads.remove(requestId); operation.cancel(); }
    }
    return _dispatchPrepared(method, params, client, requestId, receivedAt, identityKey);
  }

  Future<Object?> _dispatchPrepared(String method, Json params, _Client client, Object requestId, String receivedAt, String identityKey) async {
    final cancellation = client.sessionReads[requestId]?.merge(client.cancellation) ?? client.cancellation;
    if (method == 'mcp.auth.login' || method == 'mcp.auth.logout') {
      final deadline = TimeoutCancellationToken(const Duration(minutes: 5));
      client.mcpLogins[requestId] = deadline;
      try {
        return await callIsolate(network.port, method, {...params, 'owner': client.id},
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
        return await callIsolate(network.port, method, {...params, 'owner': client.id},
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
      return callIsolate(network.port, method, {
        ...params,
        'owner': client.id,
      }, cancellation: client.cancellation);
    }
    switch (method) {
      case 'debug.prompt-input':
        return _promptContext(params, cancellation);
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
          return await callIsolate(network.port, method, {...params, 'owner': client.id},
            cancellation: deadline.merge(client.cancellation));
        } finally {
          if (identical(client.skillSearch, deadline)) {
            client.skillSearch = null;
            client.skillSearchId = null;
          }
          deadline.cancel();
        }
      case 'providers.list':
        return callIsolate(
          network.port,
          'providers.list',
          {},
          cancellation: client.cancellation,
        );
      case 'auth.desktop':
        // Access credentials are only available to the local desktop connection.
        // Audio and transcription never pass through the task WebSocket.
        if (socketPath == null) throw StateError('Desktop authorization requires a local Unix socket');
        return callIsolate(network.port, method, {
          'refresh': params['refresh'] == true, 'owner': client.id,
        }, cancellation: client.cancellation);
      case 'auth.login':
      case 'auth.cancel':
      case 'auth.logout':
        return callIsolate(
          network.port,
          method,
          {...params, 'owner': client.id},
          onEvent: client.event,
          cancellation: client.cancellation,
        );
      case 'telemetry':
        return {
          'active_tasks': activeTaskCount,
          'resident_tasks': _tasks.length,
          'connected_clients': _clients.length,
          'pending_messages': _tasks.values.fold<int>(0, (count, task) => count + task.pending.length),
          'rss_bytes': ProcessInfo.currentRss,
          ...telemetry.snapshot(),
        };
      case 'maintenance.run':
        return maintain();
      case 'task.start':
        final config = await _config(params);
        final id = await _newTaskId(config, client.cancellation);
        if (params['client_tools'] != null) {
          _clientTools.register(
            id,
            client.id,
            params['client_tools'],
            client.send,
          );
        }
        final task = _Task(id, config);
        client.subscriptions.add(id);
        if (client.sessionProtocol) client.sessionSubscriptions.add(id);
        _begin(
          task,
          params['prompt'] as String,
          settings: {...params, 'sent_at': receivedAt}..remove('settings'),
        );
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
          _imports.remove(operationId);
          _transfers--;
        }
      default:
        final id = requiredString(params, 'task_id');
        validateTaskId(id);
        client.subscriptions.add(id);
        if (client.sessionProtocol) client.sessionSubscriptions.add(id);
        if (method == 'session.context') return _contextPage(id, params, client, cancellation);
        var task = _tasks[id] ?? _Task(id, null);
        if (task.backgroundMaintenance case final maintenance?) {
          await maintenance.future.asCancellable(cancellation);
          _lifetime.throwIfCancelled();
          task = _tasks[id] ?? _Task(id, null);
        }
        // Lazy image/tool reads can arrive together. Queue behind the current
        // SQLite owner instead of rejecting a second reader during its close.
        if ({'history.list', 'history.part', 'history.page', 'session.message.list', 'session.event.list', 'task.send', 'task.compact'}.contains(method)) {
          while (task.maintenance) {
            await task.maintenanceDone!.future.asCancellable(cancellation);
            task = _tasks[id] ?? _Task(id, null);
          }
        }
        if ({'session.message.list', 'session.event.list'}.contains(method)) {
          client.sessionSubscriptions.add(id);
          if (task.busy && task.writer == null) await task.ready?.future.asCancellable(cancellation);
          var page = File('$directory/tasks/$id/history.sqlite').existsSync()
            ? await readSession(directory, id, method, params, cancellation: cancellation)
            : <String, dynamic>{'needsProjection': true};
          if (page['needsProjection'] == true) {
            task = _tasks[id] ?? task;
            while (task.maintenance) {
              await task.maintenanceDone!.future.asCancellable(cancellation);
              task = _tasks[id] ?? task;
            }
            await _withWriter(task, (writer) => callIsolate(writer.port, 'session.prepare', {}, cancellation: cancellation));
            page = await readSession(directory, id, method, params, cancellation: cancellation);
          }
          final current = _tasks[id] ?? task;
          return {...page, 'running': current.busy, 'pending': current.pending};
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
          return {identityKey: id, 'running': task.busy, 'pending': task.pending};
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
        if (method == 'task.hibernate') {
          await _hibernate(task);
          return {identityKey: id};
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
            await callIsolate(network.port, 'validate_settings', {
              'provider': config['provider'],
              'model': config['model'],
              'settings': {...baseline, 'reasoning': effort},
            }, cancellation: client.cancellation);
            // Validation can outlive the current turn. Admit against its latest owner.
            task = _tasks[id] ?? task;
          }
          if (method == 'task.send' && task.busy) {
            if (task.cancelled) throw StateError('Task is stopping');
            if (task.pending.length >= 32) {
              throw StateError('Pending message limit reached');
            }
            if (params.keys.any(
              (key) => !{'task_id', 'prompt', 'attachments', 'delivery', 'reasoning'}.contains(key),
            )) {
              throw ArgumentError('Change task settings between turns');
            }
            final prompt = params['prompt'] as String;
            final pendingBytes = task.pending.fold<int>(0, (size, message) => size + utf8.encode(message['prompt'] as String).length);
            if (pendingBytes + utf8.encode(prompt).length > 512 * 1024) {
              throw StateError('Pending messages exceed 512 KiB');
            }
            final message = <String, dynamic>{
              'id': newId(),
              'prompt': prompt,
              if (params['attachments'] != null) 'attachments': params['attachments'],
              'delivery': mode,
              'created_at': receivedAt,
              if (params['reasoning'] != null) 'reasoning': params['reasoning'],
            };
            if (utf8.encode(jsonEncode([...task.pending, message])).length > maxClientFrameBytes - 1024) {
              throw StateError('Pending messages exceed the 64 MiB transport budget');
            }
            await task.ready?.future.asCancellable(client.cancellation);
            await _withWriter(task, (writer) async {
              final admitted = jsonObject(await callIsolate(writer.port, 'append', {
                'type': 'input.pending', 'data': message,
              }, cancellation: client.cancellation));
              task.pending.add(message);
              _broadcast(id, admitted);
              _offerSteering(task, message);
              return null;
            });
            return {
              identityKey: id,
              if (identityKey == 'sessionID') 'inboxID': 'msg_${message['id']}' else 'message_id': message['id'],
              'delivery': mode,
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
        if (method == 'history.part') {
          return _withWriter(task, (writer) => callIsolate(writer.port, 'history.part', {
            'id': requiredString(params, 'id'),
          }, cancellation: client.cancellation));
        }
        if (method == 'history.list') {
          final page = jsonObject(await _withWriter(
            task,
            (writer) => callIsolate(writer.port, 'history.list', {
              'before': params['before'],
              'limit': params['limit'] ?? 100,
            }, cancellation: client.cancellation),
          ));
          final current = _tasks[id] ?? task;
          return {...page, if (params['before'] == null) ...{
            'running': current.busy, 'pending': current.pending,
          }};
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
        if (method == 'task.fork') {
          _transfers++;
          try {
            final child = await _withWriter(
              task,
              (writer) async {
                final config = jsonObject(await callIsolate(writer.port, 'metadata',
                  {'key': 'config'}, cancellation: client.cancellation) ?? {});
                final child = await _newTaskId(config, client.cancellation);
                await callIsolate(writer.port, 'fork', {
                  'id': child, 'through': params['through'],
                }, cancellation: client.cancellation);
                return child;
              },
            );
            return {identityKey: child};
          } finally {
            _transfers--;
          }
        }
        throw StateError('Unknown method: $method');
    }
  }

  Future<Json> _promptContext(Json params, CancellationToken cancellation) async {
    final config = await _config(params);
    final id = await _newTaskId(config, cancellation);
    IsolateOwner? writer, agent;
    Json? failure;
    try {
      writer = await startStore(directory, id, ephemeral: true);
      agent = await startAgent(taskId: id, config: config, writer: writer.port,
        network: network.port, clientTools: _clientTools.port, taskTools: _taskTools.port, codeInterrupt: 0);
      await callIsolate(agent.port, 'prepare', {'prompt': params['prompt'] ?? ''},
        cancellation: cancellation, onEvent: (event) {
          if (event['type'] == 'turn.failed' || event['type'] == 'turn.cancelled') failure = event;
        });
      if (failure != null) throw StateError(failure!['data']['error'] as String);
      return jsonObject(await callIsolate(agent.port, 'context', {}, cancellation: cancellation));
    } finally {
      await agent?.close();
      await writer?.close();
      await _taskTools.release(id);
      await callIsolate(network.port, 'agents.forget', {'task_id': id});
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
        // A sleeping task uses the very same actor and restore operation as
        // inference, without admitting a turn or doing provider/tool I/O.
        final config = jsonObject(await callIsolate(writer.port, 'metadata', {'key': 'config'}, cancellation: cancellation));
        final restored = await startAgent(taskId: id, config: config,
          writer: writer.port, network: network.port, taskTools: _taskTools.port,
          clientTools: _clientTools.port, codeInterrupt: 0);
        try {
          return await callIsolate(restored.port, 'context', {}, cancellation: cancellation);
        } finally { await restored.close(); }
      }));
      return {...context, 'running': running, 'pending': pending};
    }
  }

  void _forgetIdle(_Task task) {
    if (!task.busy && !task.maintenance && task.pending.isEmpty && identical(_tasks[task.id], task)) {
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
      taskIds: network.port, cancellation: cancellation);
  }

  Future<void> _archive(_Task task, bool archived) async {
    if (task.maintenance) throw StateError('Task has a pending maintenance operation');
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
      writer = await startStore(directory, task.id, create: false);
      if (archived) await _discardPending(task, 'archived', writer: writer);
      final event = jsonObject(await callIsolate(writer.port, 'archive', {'archived': archived}, cancellation: _lifetime));
      if (archived) {
        await _taskTools.release(task.id);
        _clientTools.archive(task.id);
        await callIsolate(network.port, 'agents.forget', {'task_id': task.id}, cancellation: _lifetime);
      }
      _broadcast(task.id, event);
    } finally {
      try { await writer?.close(); }
      finally {
        task.maintenance = false;
        task.maintenanceDone = null;
        settled.complete();
        _forgetIdle(task);
      }
    }
  }

  Future<void> _hibernate(_Task task) async {
    if (task.maintenance) throw StateError('Task has a pending maintenance operation');
    task.maintenance = true;
    final settled = task.maintenanceDone = Completer<void>();
    _tasks[task.id] = task;
    IsolateOwner? writer;
    try {
      task.cancelled = true;
      task.codeInterrupt?.interrupt();
      if (task.agent != null) await callIsolate(task.agent!.port, 'cancel', {});
      await task.running;
      writer = await startStore(directory, task.id, create: false);
      await _discardPending(task, 'hibernated', writer: writer);
      await _taskTools.release(task.id);
      await callIsolate(network.port, 'agents.forget', {'task_id': task.id}, cancellation: _lifetime);
    } finally {
      await writer?.close();
      task.maintenance = false;
      task.maintenanceDone = null;
      settled.complete();
      _forgetIdle(task);
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
    final tasks = Directory('$directory/tasks');
    if (await tasks.exists()) {
      await for (final entry in tasks.list(followLinks: false)) {
        _lifetime.throwIfCancelled();
        if (entry is! Directory) continue;
        final id = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
        if (_clients.any((client) => client.id == id)) continue;
        try { validateTaskId(id); } on FormatException { continue; }
        if (!await File('${entry.path}/history.sqlite').exists() || _tasks.containsKey(id)) continue;
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
    if (task.agent == null ||
        message['delivery'] != 'steer' ||
        !task.offered.add(message['id'] as String)) {
      return;
    }
    task.codeInterrupt?.interrupt();
    task.agent!.port.send({'method': 'steer', 'params': message});
  }

  Future<void> _discardPending(_Task task, String reason, {IsolateOwner? writer}) async {
    Future<Object?> discard(IsolateOwner owner) => callIsolate(owner.port, 'session.inbox.cancel',
      {'reason': reason}, cancellation: _lifetime);
    final discarded = writer == null ? await _withWriter(task, discard) : await discard(writer);
    task.pending.clear();
    task.offered.clear();
    if (discarded != null) _broadcast(task.id, jsonObject(discarded));
  }

  Future<String> _newTaskId(Json config, CancellationToken cancellation) async =>
      await callIsolate(network.port, 'task.new_id', {'provider': config['provider']},
        cancellation: cancellation) as String;

  Future<Json> _config(Json input) async {
    final cwd = p.normalize(Directory(input['cwd'] as String? ?? Directory.current.path).absolute.path);
    if (!Directory(cwd).existsSync()) {
      throw ArgumentError('Working directory does not exist');
    }
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
    _lifetime.throwIfCancelled();
    if (_networkExited) {
      throw StateError(
        'Network worker exited; restart the server before starting a turn',
      );
    }
    if (task.busy || task.maintenance) throw StateError('Task is busy');
    if (!compact && prompt.isEmpty && (settings['attachments'] as List? ?? []).isEmpty) {
      throw const FormatException('Prompt is required');
    }
    if (_tasks.values.where((task) => task.busy).length >= maxAgents) {
      throw StateError('Active agent limit reached');
    }
    final effective = {...settings};
    if (effective['cwd'] != null) {
      final cwd = Directory(effective['cwd'] as String).absolute;
      if (!cwd.existsSync()) {
        throw ArgumentError('Working directory does not exist');
      }
      effective['cwd'] = p.normalize(cwd.path);
    }
    task.busy = true;
    task.finishing = false;
    task.ready = Completer<void>();
    _tasks[task.id] = task;
    task.cancelled = false;
    _activity.add(activeTaskCount);
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
    // Stop/archive/shutdown cancel the agent through its mailbox. Observe until
    // it commits its terminal event, regardless of the turn's total duration.
    final turnLifetime = CancellationToken();
    try {
      task.writer = await startStore(
        directory,
        task.id,
        create: task.config != null,
      );
      if (task.config != null && await callIsolate(task.writer!.port, 'metadata', {'key': 'config'}) == null) {
        // Commit admission before cancellation can stop the agent's first turn.
        // An immediately archived or stopped task must still be resumable.
        final config = {...task.config!, 'task_id': task.id};
        final created = jsonObject(await callIsolate(task.writer!.port, 'append', {
          'type': 'task.created',
          'data': config,
          'metadata': {'config': config},
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
        final inbox = await readSession(directory, task.id, 'session.inbox', {}, cancellation: turnLifetime);
        task.pending.addAll((inbox['data'] as List).map(jsonObject));
      }
      task.codeInterrupt = CodeInterrupt();
      task.agent = await startAgent(
        taskId: task.id,
        config: task.config!,
        writer: task.writer!.port,
        network: network.port,
        clientTools: _clientTools.port,
        taskTools: _taskTools.port,
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
        {'prompt': prompt, 'compact': compact, 'settings': settings},
        timeout: null,
        cancellation: turnLifetime,
        onEvent: (event) {
          if (event['type'] == 'input.committed') {
            final id = event['data']?['message_id'];
            task.pending.removeWhere((message) => message['id'] == id);
            task.offered.remove(id);
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
        await _discardPending(task, 'stopped', writer: task.writer);
      }
      await task.writer?.close();
      task.agent = null;
      task.writer = null;
      task.busy = false;
      task.finishing = false;
      task.offered.clear();
      if (terminal != null) {
        telemetry.add(terminal!['type'] as String);
        _broadcast(task.id, terminal!);
      }
      if (_closing) {
        // The durable inbox remains available when this session resumes.
      } else if (!task.cancelled && terminal?['type'] == 'turn.completed' && task.pending.isNotEmpty) {
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
      _forgetIdle(task);
    }
  }

  Future<Object?> _withWriter(
    _Task task,
    Future<Object?> Function(IsolateOwner) operation,
  ) async {
    _lifetime.throwIfCancelled();
    if (_tasks[task.id] case final current? when !identical(current, task)) {
      throw StateError('Task ownership changed; retry the operation');
    }
    if (task.maintenance) {
      throw StateError('Task has a pending maintenance operation');
    }
    if (task.busy) {
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
      writer = await startStore(
        directory,
        task.id,
        create: false,
      );
      return await operation(writer);
    } finally {
      try { await writer?.close(); }
      finally {
        task.maintenance = false;
        task.maintenanceDone = null;
        settled.complete();
        _forgetIdle(task);
      }
    }
  }

  void _broadcast(String taskId, Json event) {
    final task = _tasks[taskId];
    if (event['type'] == 'model.started' || event['type'] == 'model.retrying') {
      task?.streamOrdinal = 0;
      task?.streamPartType = null;
    }
    if (event['type'] == 'text.delta' || event['type'] == 'reasoning.delta') {
      if (task?.streamPartType != null && task?.streamPartType != event['type']) task!.streamOrdinal++;
      task?.streamPartType = event['type'] as String;
    }
    for (final client in _clients.toList()) {
      if (!client.subscriptions.contains(taskId)) continue;
      if (!client.sessionSubscriptions.contains(taskId)) {
        client.event({...event, 'task_id': taskId});
      } else if (event['session_events'] is List) {
        for (final native in event['session_events']) { client.event(jsonObject(native)); }
      } else {
        final assistant = event['assistantMessageID'] ?? _tasks[taskId]?.assistantMessageID;
        final payload = jsonObject(event['data'] ?? {});
        final type = switch (event['type']) {
          'text.delta' => 'session.text.delta',
          'reasoning.delta' => 'session.reasoning.delta',
          'compaction.delta' => 'session.compaction.delta',
          'model.retrying' || 'model.connected' || 'turn.started' => 'session.status',
          'input.pending' => 'session.inbox.enqueued',
          'input.discarded' => 'session.inbox.cancelled',
          'task.archived' => 'session.archived',
          'task.unarchived' => 'session.unarchived',
          'turn.failed' => 'session.execution.failed',
          'turn.cancelled' => 'session.execution.interrupted',
          'turn.completed' => 'session.execution.succeeded',
          _ => null,
        };
        if (type == null) continue;
        client.event({'id': 'evt_${newId()}', 'created': DateTime.now().millisecondsSinceEpoch,
          'type': type, 'data': {'sessionID': taskId,
            'assistantMessageID': ?assistant,
            if (type == 'session.text.delta' || type == 'session.reasoning.delta') ...{'ordinal': task?.streamOrdinal ?? 0, 'delta': event['delta']},
            if (type == 'session.compaction.delta') 'text': event['delta'],
            if (type == 'session.status') 'status': event['type'] == 'model.retrying'
              ? {'type': 'retry', 'attempt': event['attempt'], 'message': event['message'],
                'next': DateTime.now().millisecondsSinceEpoch + (event['delay_ms'] as int? ?? 0)} : {'type': 'busy'},
            if (type == 'session.inbox.enqueued') ...{'inboxID': 'msg_${payload['id']}', 'item': {
              'type': 'user', 'delivery': payload['delivery'], 'text': payload['prompt'], 'files': payload['attachments'] ?? []}},
            if (type == 'session.inbox.cancelled') 'ids': [for (final id in payload['ids'] as List? ?? []) 'msg_$id'],
            if (type == 'session.execution.failed') 'error': {'type': 'unknown', 'message': payload['error'].toString()},
            if (type == 'session.execution.interrupted') 'reason': 'user',
          }});
      }
    }
    if (event['type'] == 'model.started') _tasks[taskId]?.assistantMessageID = event['data']['assistantMessageID'] as String?;
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _maintenanceTimer?.cancel();
    _lifetime.cancel();
    try { await _maintenance; } catch (_) { /* Shutdown still releases all owners. */ }
    _clientTools.close();
    _files.clear();
    for (final client in _clients.toList()) {
      client.cancellation.cancel();
      await client.attachments.close();
      if (!_networkExited) {
        await callIsolate(network.port, 'mcp.detach', {'owner': client.id});
      }
    }
    await http?.close(force: true);
    for (final task in _tasks.values) {
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
    await _taskTools.close();
    unawaited(_activity.close());
    await network.close();
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
  }
}

class _Task {
  _Task(this.id, this.config);
  final String id;
  Json? config;
  String? assistantMessageID;
  int streamOrdinal = 0;
  String? streamPartType;
  bool busy = false, maintenance = false, cancelled = false, finishing = false;
  IsolateOwner? writer, agent;
  CodeInterrupt? codeInterrupt;
  Future<void>? running;
  Completer<void>? backgroundMaintenance;
  Completer<void>? maintenanceDone, writerDrained;
  int writerRequests = 0;
  Completer<void>? ready;
  final pending = <Json>[];
  final offered = <String>{};
}

class _Client {
  _Client(this.socket, String directory) : local = null {
    attachments = AttachmentUploads(directory, id);
  }
  _Client.local(String directory) : socket = null, local = StreamController<Json>() {
    attachments = AttachmentUploads(directory, id);
  }
  final WebSocket? socket;
  final StreamController<Json>? local;
  final id = newId();
  late final AttachmentUploads attachments;
  final cancellation = CancellationToken();
  CancellationToken? fileSearch;
  CancellationToken? skillSearch;
  final mcpInventories = <Object, CancellationToken>{};
  final mcpLogins = <Object, CancellationToken>{};
  final sessionReads = <Object, CancellationToken>{};
  final contextSnapshots = <String, Json>{};
  Object? fileSearchId;
  Object? skillSearchId;
  final subscriptions = <String>{};
  final sessionSubscriptions = <String>{};
  bool sessionProtocol = false;
  final _events = Queue<({String frame, int bytes})>();
  int _queuedBytes = 0;
  int credits = 256, inFlight = 0;
  void send(Json message) {
    if (local case final messages?) {
      if (!messages.isClosed) messages.add(jsonObject(jsonDecode(jsonEncode(message))));
    } else if (socket!.readyState == WebSocket.open) { socket!.add(jsonEncode(message)); }
  }

  void event(Json event) {
    if (local != null) { send({'event': event}); return; }
    if (socket!.readyState != WebSocket.open) return;
    final frame = jsonEncode({'event': event});
    if (credits > 0) {
      credits--;
      socket!.add(frame);
      return;
    }
    final bytes = utf8.encode(frame).length;
    if (_events.length >= 1024 || _queuedBytes + bytes > maxClientFrameBytes) {
      unawaited(
        socket!.close(
          1008,
          'Event backlog exceeded; reconnect and page committed history',
        ),
      );
      return;
    }
    _events.add((frame: frame, bytes: bytes));
    _queuedBytes += bytes;
  }

  void acknowledge(int count) {
    credits = (credits + count).clamp(0, 256);
    while (credits > 0 && _events.isNotEmpty && socket!.readyState == WebSocket.open) {
      final next = _events.removeFirst();
      _queuedBytes -= next.bytes;
      credits--;
      socket!.add(next.frame);
    }
  }

  Future<void> close() async {
    cancellation.cancel();
    if (local != null) { await local!.close(); }
    else { await socket!.close(); }
  }
}

/// Local calls share dispatch and snapshots with desktop's WebSocket client.
class AgentClient {
  AgentClient._(WebSocket connection, {required this.sharedFilesystem}) : socket = connection {
    _subscription = connection.listen(
      (raw) {
        final message = jsonObject(jsonDecode(raw as String));
        if (message.containsKey('event')) {
          events.add(jsonObject(message['event']));
          connection.add(
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
  AgentClient.local(AgentServer server) : socket = null, sharedFilesystem = true {
    if (server._closing) throw StateError('Server is shutting down');
    _localServer = server;
    final state = _localClient = _Client.local(server.directory);
    server._clients.add(state);
    _subscription = state.local!.stream.listen((message) {
      if (message['event'] case final Map event) events.add(jsonObject(event));
    }, onDone: _disconnected, onError: (Object _) => _disconnected());
  }
  final WebSocket? socket;
  AgentServer? _localServer;
  _Client? _localClient;
  bool _closed = false;
  Future<void>? _closingClient;
  final bool sharedFilesystem;
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
      return AgentClient._(socket, sharedFilesystem: uri.scheme == 'unix');
    } finally {
      hook.dispose();
      deadline.cancel();
      http.close();
    }
  }

  Future<Object?> request(String method, [Json params = const {}]) => _request(method, params);

  Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async {
    if (!{'session.message.list', 'session.context', 'session.event.list'}.contains(method)) {
      throw ArgumentError('Unknown session read');
    }
    return jsonObject(await _request(method, params, cancellation: cancellation));
  }


  Future<Object?> conversationPart(String reference, {required CancellationToken cancellation}) {
    final split = reference.lastIndexOf('/');
    if (split < 1) throw const FormatException('Invalid conversation content reference');
    return _request('history.part', {
      'task_id': reference.substring(0, split), 'id': reference.substring(split + 1),
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

  Future<Json> searchSkills(String cwd, String query, {required CancellationToken cancellation}) async =>
      jsonObject(await _request('skills.search', {'cwd': cwd, 'query': query},
          cancellation: cancellation, timeout: const Duration(seconds: 10)));

  Future<Json> mcpInventory({bool verbose = false, String? server, required CancellationToken cancellation}) async =>
      jsonObject(await _request('mcp.inventory', {'verbose': verbose, 'server': ?server},
        cancellation: cancellation, timeout: const Duration(seconds: 35)));

  Future<Json> mcpLogin(String server, String loginId, {required CancellationToken cancellation}) async =>
      jsonObject(await _request('mcp.auth.login', {'server': server, 'login_id': loginId},
        cancellation: cancellation, timeout: const Duration(minutes: 6)));

  Future<void> mcpLogout(String server, {required CancellationToken cancellation}) async =>
      _request('mcp.auth.logout', {'server': server}, cancellation: cancellation);

  Future<Json> desktopAuthorization({bool refresh = false, required CancellationToken cancellation}) async =>
      jsonObject(await _request('auth.desktop', {'refresh': refresh}, cancellation: cancellation,
        timeout: const Duration(seconds: 30)));

  Future<Object?> _request(String method, Json params, {
    CancellationToken? cancellation,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    cancellation?.throwIfCancelled();
    if (_closed || socket != null && socket!.readyState != WebSocket.open) {
      throw StateError('Connection is closed');
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
        if (method == 'files.search') state.fileSearch?.cancel();
        if (method == 'skills.search') state.skillSearch?.cancel();
        state.mcpInventories[id]?.cancel();
        state.mcpLogins[id]?.cancel();
      });
      state.inFlight++;
      final operation = server._dispatch(method, jsonObject(jsonDecode(jsonEncode(params))), state, id);
      server._requests.add(operation);
      unawaited(operation.then((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(() {
        server._requests.remove(operation);
        state.inFlight--;
      }));
      try {
        final result = await operation.asCancellable(token.merge(state.cancellation));
        return jsonDecode(jsonEncode(result));
      } finally { hook.dispose(); deadline.cancel(); }
    }
    final id = ++_next;
    final deadline = TimeoutCancellationToken(timeout);
    final token = cancellation == null ? deadline : cancellation.merge(deadline);
    final result = CancellableCompleter<Object?>(token, onCancel: () {
      _pending.remove(id);
      if ({'session.message.list', 'session.context', 'session.event.list'}.contains(method) && socket!.readyState == WebSocket.open) {
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
    socket!.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    try {
      return await result.future;
    } finally {
      _pending.remove(id);
      deadline.cancel();
    }
  }

  void _disconnected() {
    for (final completer in _pending.values) {
      completer.completeError(StateError('Connection closed'));
    }
    _pending.clear();
    if (!events.isClosed) unawaited(events.close());
  }

  Future<void> close() => _closingClient ??= _closeClient();
  Future<void> _closeClient() async {
    _closed = true;
    if (_localClient case final state?) {
      _localServer!._detach(state);
      await state.close();
    } else { await socket!.close(); }
    await _subscription.cancel();
    _disconnected();
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
