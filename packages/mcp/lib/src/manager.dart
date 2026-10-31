import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'events.dart';
import 'oauth.dart';
import 'transport.dart';

/// The network isolate owns this registry and its shared process generations.
class McpManager {
  McpManager({required this.http, required this.onEvent, this.publicUrl, this.directory, this.onAuthChanged});
  final HttpClient http;
  final void Function(String owner, Json event) onEvent;
  final String? publicUrl;
  final String? directory;
  final void Function(String server)? onAuthChanged;
  final lifetime = CancellationToken();
  final _servers = <String, _Server>{};
  Json _configured = {};
  final _subscriptions = <String, McpEventSubscription>{};
  Future<void> _reload = Future.value();
  List<(String, Map<String, Json>, String?)> _catalogSources = [];
  Json? _catalog;
  final _authenticating = <String>{};

  _Server _server(String name, Json config) => _Server(name, config, http,
    directory != null && config['url'] != null && config['oauth'] != false && !hasAuthorizationHeader(config)
      ? McpOAuth(directory!, name, config, http) : null, () => onAuthChanged?.call(name));

  Future<void> configure(Json config, CancellationToken cancellation) {
    final next = _reload.then((_) => _configure(config, cancellation));
    _reload = next.catchError((Object _) {});
    return next;
  }

  Future<void> _configure(Json config, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    lifetime.throwIfCancelled();
    if (config.length > 64) {
      throw ArgumentError('At most 64 global MCP servers are supported');
    }
    final normalized = <String>{};
    for (final entry in config.entries) {
      if (!normalized.add(_safeName(entry.key))) {
        throw ArgumentError('MCP server names collide after normalization');
      }
      final value = jsonObject(entry.value);
      if ((value['command'] == null) == (value['url'] == null)) {
        throw ArgumentError('MCP server needs exactly one command or URL');
      }
    }
    _configured = Map.of(config);
    for (final entry in _servers.entries.toList()) {
      cancellation.throwIfCancelled();
      lifetime.throwIfCancelled();
      if (jsonEncode(config[entry.key]) != jsonEncode(entry.value.config)) {
        for (final subscription
            in _subscriptions.values
                .where((s) => s.server == entry.key)
                .toList()) {
          await subscription.stop();
          _subscriptions.remove(subscription.id);
        }
        await entry.value.close();
        _servers.remove(entry.key);
      }
    }
    for (final entry in config.entries) {
      cancellation.throwIfCancelled();
      lifetime.throwIfCancelled();
      if (_servers.containsKey(entry.key) || entry.value['enabled'] == false) {
        continue;
      }
      final server = _server(entry.key, jsonObject(entry.value));
      _servers[entry.key] = server;
      server.start();
    }
    await Future.wait(_servers.values.map((server) => server.initial.future))
        .asCancellable(cancellation.merge(lifetime));
  }

  List<Json> status() => [
    for (final server in _servers.values)
      {
        'name': server.name,
        'state': server.state,
        'protocol_version': server.connection?.version,
        'pid': server.connection?.processId,
        'capabilities': server.connection?.discovery['capabilities'] ?? {},
        if (server.error != null) 'error': server.error,
      },
  ];

  Future<Json> login(String name, CancellationToken cancellation, void Function(String url) notify) async {
    cancellation.throwIfCancelled();
    final server = _servers[name];
    if (server?.oauth == null) throw const McpFailure('Browser sign-in is unavailable for this MCP server');
    if (!_authenticating.add(name)) throw const McpFailure('An MCP sign-in is already in progress');
    try {
      await server!.oauth!.login(cancellation.merge(lifetime).merge(server.lifetime), notify);
      // Credential installation is the commit point. Reconcile the shared
      // connection even if this client stops waiting immediately afterwards.
      await _restart(name, server, lifetime);
      return {'server': name, 'state': _servers[name]!.state, 'tool_count': _servers[name]!.tools.length};
    } finally {
      _authenticating.remove(name);
    }
  }

  Future<void> logout(String name, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    final server = _servers[name];
    if (server?.oauth == null) throw const McpFailure('OAuth sign-out is unavailable for this MCP server');
    try {
      await server!.oauth!.logout(cancellation.merge(lifetime));
    } finally {
      if (!lifetime.isCancelled) await _restart(name, server!, lifetime);
    }
  }

  void completeLogin(String name, String callbackUrl) {
    final auth = _servers[name]?.oauth;
    if (auth == null) throw const McpFailure('No MCP sign-in is waiting for a callback');
    auth.completeLogin(callbackUrl);
  }

  Future<void> _refreshAuthentication(CancellationToken cancellation) async {
    for (final entry in _servers.entries.toList()) {
      cancellation.throwIfCancelled();
      if (!_authenticating.contains(entry.key) && await entry.value.oauth?.credentialsChanged() == true) {
        try { await _restart(entry.key, entry.value, cancellation); } on CancelledException {
          cancellation.throwIfCancelled();
        }
      }
    }
  }

  Future<void> _restart(String name, _Server previous, CancellationToken cancellation) {
    final next = _reload.then((_) async {
      cancellation.throwIfCancelled();
      lifetime.throwIfCancelled();
      if (!identical(_servers[name], previous)) throw const CancelledException();
      for (final subscription in _subscriptions.values.where((s) => s.server == name).toList()) {
        await subscription.stop();
        _subscriptions.remove(subscription.id);
      }
      await previous.close();
      // Starting the replacement belongs to the manager after retiring the old
      // generation, even if this client stops waiting at the same instant.
      lifetime.throwIfCancelled();
      final replacement = _servers[name] = _server(name, previous.config);
      replacement.start();
      await replacement.initial.future.asCancellable(cancellation.merge(lifetime));
    });
    _reload = next.catchError((Object _) {});
    return next;
  }

  /// Client display data comes from the shared owner, never client-local config.
  /// Keep credentials, launch arguments, schemas and private metadata out of it.
  Future<Json> inventory(CancellationToken cancellation, {bool verbose = false, String? server}) async {
    cancellation.throwIfCancelled();
    await _refreshAuthentication(cancellation);
    final names = _configured.keys.where((name) => server == null || name == server).toList()..sort();
    final rows = await Future.wait(names.map((name) async {
      final config = jsonObject(_configured[name]);
      final enabled = config['enabled'] != false;
      final target = _servers[name];
      final state = !enabled ? 'disabled' : target?.state ?? 'starting';
      final tools = state == 'ready' ? target!.tools.values.toList() : <Json>[];
      final headers = jsonObject(config['headers'] ?? {});
      final headerEnv = jsonObject(config['header_env'] ?? {});
      final row = <String, dynamic>{
        'name': name,
        'enabled': enabled,
        'state': target?.authenticationRequired == true && enabled ? 'authentication_required' : state,
        'auth_status': _authenticating.contains(name) ? 'signing_in'
            : target?.authenticationRequired == true && enabled ? 'not_authenticated'
            : target?.oauth?.authenticated == true ? 'oauth'
            : headers.isNotEmpty || headerEnv.isNotEmpty ? 'configured_headers' : 'unsupported',
        'oauth_supported': enabled && target?.oauth != null,
        'tool_count': tools.length,
        if (target?.error != null && enabled) 'error': target!.error,
      };
      if (!verbose) return row;
      row['tools'] = tools.map((tool) => tool['name'] as String).toList()..sort();
      row['resources'] = <Json>[];
      row['resource_templates'] = <Json>[];
      if (state == 'ready' && target!.connection?.discovery['capabilities']?['resources'] != null) {
        await Future.wait([
          ('resources/list', 'resources', 'uri'),
          ('resources/templates/list', 'resource_templates', 'uriTemplate'),
        ].map((catalog) async {
          try {
            final values = await target.list(catalog.$1,
              catalog.$2 == 'resources' ? 'resources' : 'resourceTemplates', cancellation);
            row[catalog.$2] = [for (final value in values) {
              'name': value['name'],
              if (value['title'] is String) 'title': value['title'],
              catalog.$3: value[catalog.$3],
            }];
          } on CancelledException {
            rethrow;
          } catch (_) {
            row['${catalog.$2}_error'] = 'Unable to load ${catalog.$2 == 'resources' ? 'resources' : 'resource templates'}';
          }
        }));
      }
      return row;
    }));
    cancellation.throwIfCancelled();
    final result = <String, dynamic>{'servers': rows};
    if (utf8.encode(jsonEncode(result)).length > maxFrameBytes) {
      throw const McpFailure('MCP inventory exceeds the result limit; select a server');
    }
    return result;
  }

  Future<Json> catalog(CancellationToken cancellation, {String? knownRevision}) async {
    cancellation.throwIfCancelled();
    await _refreshAuthentication(cancellation);
    await Future.wait(_servers.values.map((s) => s.initial.future))
        .asCancellable(cancellation);
    // Tool maps are replaced atomically on discovery, notifications and
    // disconnect. Compare their identities before rebuilding/copying schemas.
    final sources = [for (final server in _servers.values) (
      server.name, server.tools,
      server.state == 'ready' && server.connection?.discovery['instructions'] is String
          ? server.connection!.discovery['instructions'] as String : null,
    )];
    if (_catalog == null || sources.length != _catalogSources.length ||
        List.generate(sources.length, (i) => i).any((i) => sources[i] != _catalogSources[i])) {
      _catalogSources = sources;
      _catalog = {
        'revision': newId(),
        'tools': [for (final server in _servers.values) ...server.catalog],
        'instructions': [
          for (final server in _servers.values)
            if (server.state == 'ready' &&
                server.connection?.discovery['instructions'] is String)
              {
                'server': server.name,
                'namespace': 'mcp__${_safeName(server.name)}',
                'text': server.connection!.discovery['instructions'] as String,
              },
        ],
      };
    }
    if (knownRevision == _catalog!['revision']) {
      return {'revision': knownRevision, 'unchanged': true};
    }
    return _catalog!;
  }

  Future<Json> callTool(
    String name,
    Object? arguments,
    CancellationToken cancellation,
  ) async {
    for (final server in _servers.values) {
      final tool = server.tools[name];
      if (tool == null) continue;
      final result = await server.request(
        'tools/call',
        {'name': tool['name'], 'arguments': jsonObject(arguments)},
        cancellation,
        inputSchema: jsonObject(tool['inputSchema']),
      );
      if (result['resultType'] == 'input_required') {
        throw const McpFailure(
          'MCP server requested client input; no interactive capabilities are enabled',
        );
      }
      // Code Mode must receive the complete result before it filters or prints.
      // The transport bounds messages; the agent bounds model-facing output.
      return result;
    }
    throw const McpFailure(
      'MCP tool is unavailable; inspect the current catalog',
    );
  }

  Future<Json> request(
    String server,
    String method,
    Json params,
    CancellationToken cancellation,
  ) async {
    final target = _servers[server];
    if (target == null) throw ArgumentError('Unknown global MCP server');
    return target.request(method, params, cancellation);
  }

  Future<Json> resources(
    String method,
    Json params,
    CancellationToken cancellation,
  ) async {
    if (method == 'resources/read') {
      return request(requiredString(params, 'server'), method, {
        'uri': requiredString(params, 'uri'),
      }, cancellation);
    }
    final server = params['server'] as String?;
    if (server != null) {
      return request(server, method, {
        if (params['cursor'] != null) 'cursor': params['cursor'],
      }, cancellation);
    }
    if (params['cursor'] != null) {
      throw ArgumentError('A resource cursor requires its server name');
    }
    final key = method == 'resources/list' ? 'resources' : 'resourceTemplates';
    final values = <Json>[];
    final cursors = <String, String>{};
    for (final entry in _servers.entries) {
      if (entry.value.connection?.discovery['capabilities']?['resources'] ==
          null) {
        continue;
      }
      final result = await entry.value.request(method, {}, cancellation);
      for (final value in result[key] as List? ?? []) {
        values.add({...jsonObject(value), 'server': entry.key});
      }
      if (result['nextCursor'] is String) {
        cursors[entry.key] = result['nextCursor'] as String;
      }
      if (values.length > 1000) {
        throw const McpFailure(
          'Resource catalog exceeds the result limit; select a server',
        );
      }
    }
    return {key: values, if (cursors.isNotEmpty) 'next_cursors': cursors};
  }

  Future<Json> subscribe(
    String owner,
    Json params,
    CancellationToken cancellation,
  ) async {
    lifetime.throwIfCancelled();
    cancellation.throwIfCancelled();
    if (_subscriptions.values.where((v) => v.owner == owner).length >= 64 ||
        _subscriptions.length >= 256) {
      throw const McpFailure('MCP event subscription limit reached');
    }
    final server = requiredString(params, 'server');
    final target = _servers[server];
    if (target == null) throw ArgumentError('Unknown global MCP server');
    final connection = await target.ready(cancellation);
    if (!connection.modern ||
        connection.discovery['capabilities']?['events'] == null) {
      throw const McpFailure('MCP server does not advertise the Events draft');
    }
    final definitions = await target.list(
      'events/list',
      'events',
      cancellation,
    );
    final name = requiredString(params, 'name');
    final candidates = definitions.where((v) => v['name'] == name);
    if (candidates.isEmpty) throw ArgumentError('Unknown MCP event');
    final definition = candidates.single;
    final supported = (definition['delivery'] as List).cast<String>();
    final mode =
        params['mode'] as String? ??
        ['push', 'poll', 'webhook'].firstWhere(
          (value) =>
              supported.contains(value) &&
              (value != 'webhook' || publicUrl != null),
          orElse: () => throw const McpFailure('No usable event delivery mode'),
        );
    if (!supported.contains(mode)) {
      throw ArgumentError('Event does not support the requested delivery mode');
    }
    final subscription = McpEventSubscription(
      id: newId(),
      owner: owner,
      server: server,
      name: name,
      arguments: jsonObject(params['arguments'] ?? {}),
      mode: mode,
      cursor: params['cursor'] as String?,
      maxAgeMs: params['max_age_ms'] as int?,
      ttlMs: params.containsKey('ttl_ms') ? params['ttl_ms'] as int? : 300000,
      publicUrl: publicUrl,
      connection: target.ready,
      onEvent: (event) =>
          onEvent(owner, {'task_id': params['task_id'], ...event}),
    );
    _subscriptions[subscription.id] = subscription;
    try {
      await subscription.start(cancellation);
      return subscription.toJson();
    } catch (_) {
      await subscription.stop();
      _subscriptions.remove(subscription.id);
      rethrow;
    }
  }

  List<Json> subscriptions(String owner) => _subscriptions.values
      .where((s) => s.owner == owner)
      .map((s) => s.toJson())
      .toList();

  Future<void> unsubscribe(String owner, String id) async {
    final subscription = _subscriptions[id];
    if (subscription == null) return;
    if (subscription.owner != owner) {
      throw ArgumentError('Subscription belongs to another client');
    }
    await subscription.stop();
    _subscriptions.remove(id);
  }

  Future<void> detach(String owner) async {
    await Future.wait(
      _subscriptions.values
          .where((s) => s.owner == owner)
          .toList()
          .map((s) => unsubscribe(owner, s.id)),
    );
  }

  Json webhook(String id, Json headers, List<int> body) {
    final subscription = _subscriptions[id];
    if (subscription == null) return {'status': 410};
    return subscription.webhook(headers, body);
  }

  Future<void> close() async {
    lifetime.cancel();
    await _reload;
    await Future.wait(_subscriptions.values.toList().map((s) => s.stop()));
    _subscriptions.clear();
    await Future.wait(_servers.values.toList().map((s) => s.close()));
    _servers.clear();
  }
}

class _Server {
  _Server(this.name, this.config, this.http, this.oauth, this.onAuthChanged);
  final String name;
  final Json config;
  final HttpClient http;
  final McpOAuth? oauth;
  final void Function() onAuthChanged;
  final lifetime = CancellationToken();
  final initial = Completer<void>();
  Future<void>? _runner, _refreshing;
  McpConnection? connection;
  String state = 'starting';
  String? error;
  bool authenticationRequired = false;
  Map<String, Json> tools = {};
  List<Json> get catalog => [
    for (final entry in tools.entries)
      {
        'name': entry.key,
        'namespace': 'mcp__${_safeName(name)}',
        'tool_name': _safeName(entry.value['name'] as String),
        'original_name': entry.value['name'],
        'server_name': name,
        if (entry.value['title'] is String) 'title': entry.value['title'],
        'description': entry.value['description'] as String? ?? '',
        'parameters': entry.value['inputSchema'],
        if (entry.value['outputSchema'] != null) 'output_schema': entry.value['outputSchema'],
      },
  ];

  void start() {
    _runner = _run();
  }

  Future<void> _run() async {
    var failures = 0;
    while (!lifetime.isCancelled && failures < 6) {
      final since = Stopwatch()..start();
      final current = McpConnection(config, http, _notification,
        authorization: oauth?.authorization, onAuthChallenge: oauth?.challenge);
      connection = current;
      try {
        state = 'connecting';
        await current.connect(lifetime);
        await _refresh();
        state = 'ready';
        error = null;
        final wasRequired = authenticationRequired;
        authenticationRequired = false;
        if (wasRequired || oauth?.authenticated == true) onAuthChanged();
        if (!initial.isCompleted) initial.complete();
        unawaited(_listen(current));
        await current.closed.future.asCancellable(lifetime);
      } on CancelledException {
        if (lifetime.isCancelled) break;
      } catch (failure) {
        authenticationRequired = failure is McpFailure && (failure.status == 401 || failure.status == 403);
        error = authenticationRequired ? 'MCP server requires authentication' : 'MCP connection unavailable';
        if (authenticationRequired) onAuthChanged();
      } finally {
        await current.close();
        tools = {};
        if (!initial.isCompleted) initial.complete();
      }
      if (lifetime.isCancelled) break;
      if (authenticationRequired && oauth?.canRefresh != true) { state = 'failed'; break; }
      if (since.elapsed > const Duration(minutes: 1)) failures = 0;
      failures++;
      state = failures == 6 ? 'failed' : 'reconnecting';
      if (failures < 6) {
        try {
          await cancellableDelay(
            Duration(milliseconds: 250 * (1 << (failures - 1))),
            lifetime,
          );
        } on CancelledException {
          break;
        }
      }
    }
    if (lifetime.isCancelled) state = 'closed';
  }

  Future<McpConnection> ready(CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    await initial.future.asCancellable(cancellation);
    final value = connection;
    if (state != 'ready' || value == null || value.lifetime.isCancelled) {
      throw const McpFailure('MCP server is unavailable or reconnecting');
    }
    return value;
  }

  Future<Json> request(
    String method,
    Json params,
    CancellationToken cancellation, {
    Json? inputSchema,
  }) async {
    final current = await ready(cancellation);
    try {
      return await current.request(
        method,
        params,
        cancellation: cancellation,
        inputSchema: inputSchema,
      );
    } on SocketException {
      unawaited(current.close());
      throw const McpFailure(
        'MCP transport disconnected; an interrupted call may have taken effect',
      );
    } on McpFailure catch (failure) {
      if (failure.status == 401 || failure.status == 403) {
        authenticationRequired = true;
        error = 'MCP server requires authentication';
        tools = {};
        onAuthChanged();
        unawaited(current.close());
      }
      rethrow;
    }
  }

  Future<List<Json>> list(
    String method,
    String key,
    CancellationToken cancellation, {
    bool connecting = false,
  }) async {
    final result = <Json>[];
    final seen = <String>{};
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final value = connecting
          ? await connection!.request(method, {
              'cursor': ?cursor,
            }, cancellation: cancellation)
          : await request(method, {'cursor': ?cursor}, cancellation);
      result.addAll((value[key] as List? ?? []).map(jsonObject));
      if (result.length > 1000 ||
          utf8.encode(jsonEncode(result)).length > maxFrameBytes) {
        throw const McpFailure('MCP catalog exceeds the configured bound');
      }
      cursor = value['nextCursor'] as String?;
      if (cursor == null) return result;
      if (!seen.add(cursor)) {
        throw const McpFailure('MCP catalog cursor repeated');
      }
    }
    throw const McpFailure('MCP catalog exceeds 20 pages');
  }

  Future<void> _refresh() =>
      _refreshing ??= _loadTools().whenComplete(() => _refreshing = null);
  Future<void> _loadTools() async {
    final current = connection!;
    if (current.discovery['capabilities']?['tools'] == null) {
      tools = {};
      return;
    }
    final list = await this.list(
      'tools/list',
      'tools',
      lifetime,
      connecting: true,
    );
    final next = <String, Json>{};
    for (final tool in list) {
      if (config['url'] != null) {
        try {
          schemaHeaders(jsonObject(tool['inputSchema']), {});
        } on FormatException {
          continue;
        }
      }
      final callable =
          'mcp__${_safeName(name)}__${_safeName(requiredString(tool, 'name'))}';
      if (next.containsKey(callable)) {
        throw const McpFailure('MCP tool names collide after normalization');
      }
      next[callable] = tool;
    }
    if (identical(connection, current) && !current.lifetime.isCancelled) {
      tools = next;
    }
  }

  void _notification(Json notification) {
    if (notification['method'] == 'notifications/tools/list_changed') {
      unawaited(
        _refresh().catchError((Object _) {
          error = 'MCP tool catalog refresh failed';
        }),
      );
    }
  }

  Future<void> _listen(McpConnection current) async {
    if (!current.modern ||
        current.discovery['capabilities']?['tools']?['listChanged'] != true) {
      return;
    }
    var delay = 250;
    while (!lifetime.isCancelled && !current.lifetime.isCancelled) {
      final attempt = CancellationToken();
      final token = lifetime.merge(current.lifetime).merge(attempt);
      var acknowledged = false;
      final activation = Timer(
        const Duration(seconds: 15),
        () => attempt.cancel(
          TimeoutException('MCP catalog subscription did not activate'),
        ),
      );
      try {
        await current.request(
          'subscriptions/listen',
          {
            'notifications': {'toolsListChanged': true},
          },
          cancellation: token,
          timeout: null,
          onNotification: (notification) {
            if (notification['method'] ==
                'notifications/subscriptions/acknowledged') {
              activation.cancel();
              acknowledged =
                  notification['params']?['notifications']?['toolsListChanged'] ==
                  true;
              if (!acknowledged) {
                attempt.cancel(
                  const McpFailure('MCP server declined catalog notifications'),
                );
              }
            } else if (acknowledged) {
              _notification(notification);
            }
          },
        );
      } catch (_) {
        if (!acknowledged) return;
      } finally {
        activation.cancel();
        attempt.cancel();
      }
      if (token.isCancelled &&
          (lifetime.isCancelled || current.lifetime.isCancelled)) {
        return;
      }
      try {
        await cancellableDelay(
          Duration(milliseconds: delay),
          lifetime.merge(current.lifetime),
        );
        await _refresh();
      } catch (_) {
        return;
      }
      delay = (delay * 2).clamp(250, 8000);
    }
  }

  Future<void> close() async {
    lifetime.cancel();
    await connection?.close();
    await oauth?.close();
    await _runner;
  }
}

String _safeName(String value) =>
    value.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
