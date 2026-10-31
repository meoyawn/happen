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
  final _requests = <Future<Object?>>{};
  bool _closing = false;
  bool _networkExited = false;
  Timer? _maintenanceTimer;
  Future<Json>? _maintenance;
  int _transfers = 0;

  static Future<AgentServer> start({
    required String directory,
    String host = '127.0.0.1',
    int port = 8765,
    String? token,
    String? endpoint,
    String? configPath,
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
        configPath: configPath,
        events: events.sendPort,
      );
    } catch (_) {
      events.close();
      rethrow;
    }
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
                agent.port.send({'method': 'cancel', 'params': {}});
              }
            }
          }
        }),
      );
      http.listen(server._accept);
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

  /// Embedding keeps the client and server in one process, using UDS for the API.
  static Future<AgentServer> startEmbedded({
    required String directory,
    String? endpoint,
    String? configPath,
    bool telemetry = true,
  }) async {
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
          if (raw is! String || utf8.encode(raw).length > maxFrameBytes) {
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

  Future<Object?> _dispatch(String method, Json params, _Client client) async {
    _lifetime.throwIfCancelled();
    if (_closing) throw StateError('Server is shutting down');
    final receivedAt = DateTime.now().toUtc().toIso8601String();
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
      case 'providers.list':
        return callIsolate(
          network.port,
          'providers.list',
          {},
          cancellation: client.cancellation,
        );
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
          'active_tasks': _tasks.values.where((task) => task.busy).length,
          'resident_tasks': _tasks.length,
          'connected_clients': _clients.length,
          'pending_messages': _tasks.values.fold<int>(0, (count, task) => count + task.pending.length),
          'rss_bytes': ProcessInfo.currentRss,
          ...telemetry.snapshot(),
        };
      case 'maintenance.run':
        return maintain();
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
        final task = _Task(id, config);
        client.subscriptions.add(id);
        _begin(
          task,
          requiredString(params, 'prompt'),
          settings: {...params, 'sent_at': receivedAt}..remove('settings'),
        );
        return {'task_id': id};
      case 'history.import':
        final targetDirectory = directory;
        final source = requiredString(params, 'path');
        final operationId = params['operation_id'] as String?;
        _transfers++;
        try {
          final id = await importHistory(
            targetDirectory, source, operationId: operationId,
            cancellation: client.cancellation,
          );
          return {'task_id': id};
        } finally {
          _transfers--;
        }
      default:
        final id = requiredString(params, 'task_id');
        validateTaskId(id);
        client.subscriptions.add(id);
        var task = _tasks[id] ?? _Task(id, null);
        if (task.backgroundMaintenance case final maintenance?) {
          await maintenance.future;
          _lifetime.throwIfCancelled();
          task = _tasks[id] ?? _Task(id, null);
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
          return {'task_id': id, 'running': task.busy, 'pending': task.pending};
        }
        if (method == 'task.archive' || method == 'task.unarchive') {
          await _archive(task, method == 'task.archive');
          return {'task_id': id, 'archived': method == 'task.archive'};
        }
        if (method == 'task.cancel') {
          task.cancelled = true;
          _discardPending(task, 'cancelled');
          final agent = task.agent;
          if (agent != null) await callIsolate(agent.port, 'cancel', {});
          return null;
        }
        if (method == 'task.send' || method == 'task.compact') {
          final mode = params['delivery'] as String? ?? 'queue';
          if (!{'steer', 'queue'}.contains(mode)) {
            throw ArgumentError('Delivery must be steer or queue');
          }
          if (method == 'task.send' && task.busy) {
            if (task.cancelled) throw StateError('Task is stopping');
            if (task.pending.length >= 32) {
              throw StateError('Pending message limit reached');
            }
            if (params.keys.any(
              (key) => !{'task_id', 'prompt', 'delivery'}.contains(key),
            )) {
              throw ArgumentError('Change task settings between turns');
            }
            final prompt = requiredString(params, 'prompt');
            final pendingBytes = task.pending.fold<int>(0, (size, message) => size + utf8.encode(message['prompt'] as String).length);
            if (pendingBytes + utf8.encode(prompt).length > 512 * 1024) {
              throw StateError('Pending messages exceed 512 KiB');
            }
            final message = <String, dynamic>{
              'id': newId(),
              'prompt': prompt,
              'delivery': mode,
              'created_at': receivedAt,
            };
            task.pending.add(message);
            _broadcast(id, {
              'task_id': id,
              'type': 'input.pending',
              'data': message,
            });
            _offerSteering(task, message);
            return {
              'task_id': id,
              'message_id': message['id'],
              'delivery': mode,
            };
          }
          _begin(
            task,
            params['prompt'] as String? ?? '',
            compact: method == 'task.compact',
            settings: {...params, 'sent_at': receivedAt},
          );
          return {'task_id': id};
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
          final child = newId();
          _transfers++;
          try {
            await _withWriter(
              task,
              (writer) => callIsolate(writer.port, 'fork', {
                'id': child, 'through': params['through'],
              }, cancellation: client.cancellation),
            );
          } finally {
            _transfers--;
          }
          return {'task_id': child};
        }
        throw StateError('Unknown method: $method');
    }
  }

  void _forgetIdle(_Task task) {
    if (!task.busy && !task.maintenance && task.pending.isEmpty && identical(_tasks[task.id], task)) {
      _tasks.remove(task.id);
    }
  }

  Future<void> _archive(_Task task, bool archived) async {
    if (task.maintenance) throw StateError('Task has a pending maintenance operation');
    task.maintenance = true;
    _tasks[task.id] = task;
    IsolateOwner? writer;
    try {
      if (task.busy) {
        task.cancelled = true;
        _discardPending(task, 'archived');
        if (task.agent != null) await callIsolate(task.agent!.port, 'cancel', {});
        await task.running;
      }
      _lifetime.throwIfCancelled();
      writer = await startStore(directory, task.id, create: false, legacyDecoder: gptItemFromNative);
      final event = jsonObject(await callIsolate(writer.port, 'archive', {'archived': archived}, cancellation: _lifetime));
      if (archived) _clientTools.archive(task.id);
      for (final client in _clients.toList()) {
        client.event({'task_id': task.id, ...event});
      }
    } finally {
      await writer?.close();
      task.maintenance = false;
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
    task.agent!.port.send({'method': 'steer', 'params': message});
  }

  void _discardPending(_Task task, String reason) {
    if (task.pending.isEmpty) return;
    final ids = task.pending.map((message) => message['id']).toList();
    task.pending.clear();
    task.offered.clear();
    _broadcast(task.id, {
      'task_id': task.id,
      'type': 'input.discarded',
      'data': {'ids': ids, 'reason': reason},
    });
  }

  Future<Json> _config(Json input) async {
    final cwd = Directory(input['cwd'] as String? ?? Directory.current.path)
        .absolute
        .path;
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
    if (!compact && prompt.isEmpty) {
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
      effective['cwd'] = cwd.path;
    }
    task.busy = true;
    _tasks[task.id] = task;
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
      final turn = callIsolate(
        task.agent!.port,
        'turn',
        {'prompt': prompt, 'compact': compact, 'settings': settings},
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
    } finally {
      await task.agent?.close();
      await task.writer?.close();
      task.agent = null;
      task.writer = null;
      task.busy = false;
      task.offered.clear();
      if (terminal != null) {
        telemetry.add(terminal!['type'] as String);
        _broadcast(task.id, terminal!);
      }
      if (_closing || task.cancelled || terminal?['type'] != 'turn.completed') {
        _discardPending(task, 'stopped');
      } else if (task.pending.isNotEmpty) {
        final next = task.pending.first;
        try {
          _begin(
            task,
            next['prompt'] as String,
            settings: {'message_id': next['id'], 'sent_at': next['created_at']},
          );
        } catch (_) {
          _discardPending(task, 'could_not_start');
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
      final writer = task.writer;
      if (writer == null) throw StateError('Task is starting; retry shortly');
      return operation(writer);
    }
    task.maintenance = true;
    _tasks[task.id] = task;
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
      _forgetIdle(task);
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
    _maintenanceTimer?.cancel();
    _lifetime.cancel();
    try { await _maintenance; } catch (_) { /* Shutdown still releases all owners. */ }
    _clientTools.close();
    for (final client in _clients.toList()) {
      client.cancellation.cancel();
      if (!_networkExited) {
        await callIsolate(network.port, 'mcp.detach', {'owner': client.id});
      }
    }
    await http.close(force: true);
    for (final task in _tasks.values) {
      task.cancelled = true;
      if (task.agent != null) {
        unawaited(callIsolate(task.agent!.port, 'cancel', {}));
      }
    }
    await Future.wait(
      _tasks.values.map((task) => task.running ?? Future<void>.value()),
    );
    await Future.wait(_requests.toList().map((operation) => operation.catchError((Object _) => null)));
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
  Completer<void>? backgroundMaintenance;
  final pending = <Json>[];
  final offered = <String>{};
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
    if (socket.readyState != WebSocket.open) {
      throw StateError('Connection is closed');
    }
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
