import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'events.dart';
import 'oauth.dart';
import 'transport.dart';
import 'timeouts.dart';

/// The network isolate owns this registry and its shared process generations.
class McpManager {
  McpManager({required this.http, required this.onEvent, this.publicUrl, this.directory, this.onAuthChanged, this.acceptThreadEvent, this.persistSubscription,
    this.clientCapabilities = const {}, this.requestMetadata});
  final Json clientCapabilities;
  final McpRequestMetadata? requestMetadata;
  final HttpClient http;
  final void Function(String owner, Json event) onEvent;
  final String? publicUrl;
  final String? directory;
  final void Function(String server)? onAuthChanged;
  final Future<void> Function(Json event, CancellationToken cancellation)? acceptThreadEvent;
  final Future<void> Function(String operation, Json params, CancellationToken cancellation)? persistSubscription;
  final lifetime = CancellationToken();
  final _servers = <String, _Server>{};
  final _localServers = <String, Map<String, _Server>>{};
  final _localConfigured = <String, Json>{};
  final _processes = <String, _Connection>{};
  final _connections = <_Connection>{};
  Json _configured = {};
  final _subscriptions = <String, McpEventSubscription>{};
  final _subscriptionTargets = <String, _Server>{};
  Future<void> _reload = Future.value();
  final _catalogs = <String, ({List<(String, Map<String, Json>, String?)> sources, Json value})>{};
  final _authenticating = <_Server>{};

  Map<String, _Server> _visible(String? scope) => scope == null ? _servers : {
    for (final entry in _servers.entries) if (!(_localConfigured[scope]?.containsKey(entry.key) ?? false)) entry.key: entry.value,
    ...?_localServers[scope],
  };
  Json _configuration(String? scope) => {..._configured, if (scope != null) ...?_localConfigured[scope]};
  Iterable<_Server> get _bindings => [..._servers.values, for (final servers in _localServers.values) ...servers.values];

  Json _launch(Json config) => config['command'] == null ? config : {
    'command': config['command'], 'args': config['args'] ?? <String>[],
    'cwd': Directory(config['cwd'] as String? ?? Directory.current.path).absolute.uri.normalizePath().toFilePath(),
    'env': mcpEnvironment(config),
  };

  _Server _server(String name, Json config, String? executableRevision, String? scope) {
    final launch = _launch(config);
    final key = jsonEncode([_ordered(launch), executableRevision]);
    _Connection create() {
      final connection = _Connection(config['command'] == null ? launch : {...launch, 'legacy_fallback': true}, http,
        directory != null && config['url'] != null && config['oauth'] != false && !hasAuthorizationHeader(config)
          ? McpOAuth(directory!, name, config, http) : null, () => onAuthChanged?.call(name), clientCapabilities, requestMetadata);
      _connections.add(connection); connection.start(); return connection;
    }
    final connection = config['command'] == null ? create() : _processes.putIfAbsent(key, create);
    return _Server(name, config, executableRevision, scope, connection);
  }

  Future<void> _retire(_Server server) async {
    for (final subscription in _subscriptions.values.where((s) => identical(_subscriptionTargets[s.id], server)).toList()) {
      await subscription.stop(); _subscriptions.remove(subscription.id); _subscriptionTargets.remove(subscription.id);
    }
    server.close();
  }

  Future<void> _prune() async {
    final live = _bindings.map((binding) => binding.shared).toSet();
    for (final connection in _connections.difference(live)) {
      _processes.removeWhere((_, value) => identical(value, connection));
      _connections.remove(connection); await connection.close();
    }
  }

  Future<void> configure(Json config, CancellationToken cancellation, {
    Map<String, String> executableRevisions = const {},
    String? scope,
  }) {
    final next = _reload.then((_) => _configure(config, cancellation, executableRevisions, scope));
    _reload = next.catchError((Object _) {});
    return next;
  }

  Future<void> _configure(Json config, CancellationToken cancellation, Map<String, String> executableRevisions, String? scope) async {
    cancellation.throwIfCancelled();
    lifetime.throwIfCancelled();
    void validate(Json values) {
      if (values.length > 64) throw ArgumentError('At most 64 MCP servers per scope are supported');
      final normalized = <String>{};
      for (final entry in values.entries) {
      if (!normalized.add(_safeName(entry.key))) {
        throw ArgumentError('MCP server names collide after normalization');
      }
      final value = jsonObject(entry.value);
      if ((value['command'] == null) == (value['url'] == null)) {
        throw ArgumentError('MCP server needs exactly one command or URL');
      }
      }
    }
    validate(scope == null ? config : {..._configured, ...config});
    if (scope == null) {
      validate(config);
      for (final local in _localConfigured.values) { validate({...config, ...local}); }
      _configured = Map.of(config);
    } else { _localConfigured[scope] = Map.of(config); }
    final servers = scope == null ? _servers : _localServers.putIfAbsent(scope, () => {});
    try {
    final rebuilding = <_Connection, String?>{};
    for (final entry in config.entries) {
      final value = jsonObject(entry.value);
      if (value['command'] == null || value['enabled'] == false) continue;
      final launch = jsonEncode(_ordered(_launch(value)));
      for (final binding in _bindings) {
        if (binding.config['command'] != null && binding.executableRevision != executableRevisions[entry.key] &&
            jsonEncode(_ordered(_launch(binding.config))) == launch) {
          rebuilding[binding.shared] = executableRevisions[entry.key];
        }
      }
    }
    for (final rebuild in rebuilding.entries) {
      final affected = _bindings.where((binding) => identical(binding.shared, rebuild.key)).toList();
      // Executable generations belong to the physical launch, not the config
      // scope which noticed the rebuild. Drain every owner before launching.
      for (final binding in affected) {
        await _retire(binding);
        (binding.scope == null ? _servers : _localServers[binding.scope]!).remove(binding.name);
      }
      await _prune();
      lifetime.throwIfCancelled();
      // Once retirement begins, restoring all bindings is manager-owned even
      // if the initiating reload is cancelled while the old process drains.
      for (final binding in affected) {
        final value = binding.scope == scope ? config[binding.name] : binding.config;
        if (value == null || value['enabled'] == false) continue;
        final revision = binding.scope == scope ? executableRevisions[binding.name] : rebuild.value;
        (binding.scope == null ? _servers : _localServers[binding.scope]!)[binding.name] =
          _server(binding.name, jsonObject(value), revision, binding.scope);
      }
    }
    for (final entry in servers.entries.toList()) {
      cancellation.throwIfCancelled();
      lifetime.throwIfCancelled();
      if (jsonEncode(_ordered(config[entry.key])) != jsonEncode(_ordered(entry.value.config)) ||
          executableRevisions[entry.key] != entry.value.executableRevision) {
        await _retire(entry.value);
        servers.remove(entry.key);
      }
    }
    await _prune();
    for (final entry in config.entries) {
      cancellation.throwIfCancelled();
      lifetime.throwIfCancelled();
      if (servers.containsKey(entry.key) || entry.value['enabled'] == false) {
        continue;
      }
      servers[entry.key] = _server(entry.key, jsonObject(entry.value), executableRevisions[entry.key], scope);
    }
    } finally { await _prune(); }
    await Future.wait(servers.values.map((server) => server.initial.future))
        .asCancellable(cancellation.merge(lifetime));
  }

  List<Json> status({String? scope}) => [
    for (final server in _visible(scope).values)
      {
        'name': server.name,
        'state': server.state,
        'protocol_version': server.connection?.version,
        'pid': server.connection?.processId,
        'capabilities': server.connection?.discovery['capabilities'] ?? <String, Object?>{},
        if (server.error != null) 'error': server.error,
      },
  ];

  Future<Json> login(String name, CancellationToken cancellation, void Function(String url) notify, {String? scope}) async {
    cancellation.throwIfCancelled();
    final server = _visible(scope)[name];
    if (server?.oauth == null) throw const McpFailure('Browser sign-in is unavailable for this MCP server');
    if (!_authenticating.add(server!)) throw const McpFailure('An MCP sign-in is already in progress');
    try {
      await server.oauth!.login(cancellation.merge(lifetime).merge(server.lifetime), notify);
      // Credential installation is the commit point. Reconcile the shared
      // connection even if this client stops waiting immediately afterwards.
      await _restart(name, server, lifetime);
      final replacement = _visible(scope)[name]!;
      return {'server': name, 'state': replacement.state, 'tool_count': replacement.tools.length};
    } finally {
      _authenticating.remove(server);
    }
  }

  Future<void> logout(String name, CancellationToken cancellation, {String? scope}) async {
    cancellation.throwIfCancelled();
    final server = _visible(scope)[name];
    if (server?.oauth == null) throw const McpFailure('OAuth sign-out is unavailable for this MCP server');
    try {
      await server!.oauth!.logout(cancellation.merge(lifetime));
    } finally {
      if (!lifetime.isCancelled) await _restart(name, server!, lifetime);
    }
  }

  void completeLogin(String name, String callbackUrl, {String? scope}) {
    final auth = _visible(scope)[name]?.oauth;
    if (auth == null) throw const McpFailure('No MCP sign-in is waiting for a callback');
    auth.completeLogin(callbackUrl);
  }

  Future<void> _refreshAuthentication(CancellationToken cancellation) async {
    for (final server in _bindings.toList()) {
      cancellation.throwIfCancelled();
      if (!_authenticating.contains(server) && await server.oauth?.credentialsChanged() == true) {
        try { await _restart(server.name, server, cancellation); } on CancelledException {
          cancellation.throwIfCancelled();
        }
      }
    }
  }

  Future<void> _restart(String name, _Server previous, CancellationToken cancellation) {
    final next = _reload.then((_) async {
      cancellation.throwIfCancelled();
      lifetime.throwIfCancelled();
      final servers = previous.scope == null ? _servers : _localServers[previous.scope]!;
      if (!identical(servers[name], previous)) throw const CancelledException();
      await _retire(previous);
      servers.remove(name);
      await _prune();
      // Starting the replacement belongs to the manager after retiring the old
      // generation, even if this client stops waiting at the same instant.
      lifetime.throwIfCancelled();
      final replacement = servers[name] = _server(name, previous.config, previous.executableRevision, previous.scope);
      await replacement.initial.future.asCancellable(cancellation.merge(lifetime));
    });
    _reload = next.catchError((Object _) {});
    return next;
  }

  /// Client display data comes from the shared owner, never client-local config.
  /// Keep credentials, launch arguments, schemas and private metadata out of it.
  Future<Json> inventory(CancellationToken cancellation, {bool verbose = false, String? server, String? scope}) async {
    cancellation.throwIfCancelled();
    await _refreshAuthentication(cancellation);
    final configured = _configuration(scope), servers = _visible(scope);
    final names = configured.keys.where((name) => server == null || name == server).toList()..sort();
    final rows = await Future.wait(names.map((name) async {
      final config = jsonObject(configured[name]);
      final enabled = config['enabled'] != false;
      final target = servers[name];
      final state = !enabled ? 'disabled' : target?.state ?? 'starting';
      final tools = state == 'ready' ? target!.tools.values.toList() : <Json>[];
      final headers = jsonObject(config['headers'] ?? {});
      final headerEnv = jsonObject(config['header_env'] ?? {});
      final row = <String, dynamic>{
        'name': name,
        'enabled': enabled,
        'state': target?.authenticationRequired == true && enabled ? 'authentication_required' : state,
        'auth_status': _authenticating.contains(target) ? 'signing_in'
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

  Future<Json> catalog(CancellationToken cancellation, {String? knownRevision, String? scope}) async {
    cancellation.throwIfCancelled();
    await _refreshAuthentication(cancellation);
    final servers = _visible(scope);
    await Future.wait(servers.values.map((s) => s.initial.future))
        .asCancellable(cancellation);
    // Tool maps are replaced atomically on discovery, notifications and
    // disconnect. Compare their identities before rebuilding/copying schemas.
    final sources = [for (final server in servers.values) (
      server.name, server.tools,
      server.state == 'ready' && server.connection?.discovery['instructions'] is String
          ? server.connection!.discovery['instructions'] as String : null,
    )];
    var cached = _catalogs[scope ?? ''];
    if (cached == null || sources.length != cached.sources.length ||
        List.generate(sources.length, (i) => i).any((i) => sources[i] != cached!.sources[i])) {
      final value = <String, dynamic>{
        'revision': newId(),
        'tools': [for (final server in servers.values) ...server.catalog],
        'instructions': [
          for (final server in servers.values)
            if (server.state == 'ready' &&
                server.connection?.discovery['instructions'] is String)
              {
                'server': server.name,
                'namespace': 'mcp__${_safeName(server.name)}',
                'text': server.connection!.discovery['instructions'] as String,
              },
        ],
      };
      cached = _catalogs[scope ?? ''] = (sources: sources, value: value);
    }
    if (knownRevision == cached.value['revision']) {
      return {'revision': knownRevision, 'unchanged': true};
    }
    return cached.value;
  }

  Future<Json> callTool(
    String name,
    Object? arguments,
    CancellationToken cancellation, {String? scope, McpInputHandler? onInput, Json? meta,
      Duration? timeout = mcpToolTimeout, bool readOnly = false}
  ) async {
    for (final server in _visible(scope).values) {
      final tool = server.tools[name];
      if (tool == null) continue;
      final result = await server.request(
        'tools/call',
        {'name': tool['name'], 'arguments': jsonObject(arguments), '_meta': ?meta},
        cancellation,
        inputSchema: jsonObject(tool['inputSchema']),
        onInput: onInput, timeout: mcpRequestedToolTimeout(timeout), readOnly: readOnly,
        retrySafe: tool['annotations']?['readOnlyHint'] == true ||
            tool['annotations']?['idempotentHint'] == true,
      );
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
    CancellationToken cancellation, {String? scope, McpInputHandler? onInput,
      Duration? timeout = mcpToolTimeout, bool readOnly = false}
  ) async {
    final target = _visible(scope)[server];
    if (target == null) throw ArgumentError('Unknown MCP server in this scope');
    return target.request(method, params, cancellation, onInput: onInput, timeout: timeout, readOnly: readOnly);
  }

  Future<Json> resources(
    String method,
    Json params,
    CancellationToken cancellation, {String? scope, McpInputHandler? onInput,
      Duration? timeout = mcpToolTimeout, bool readOnly = false}
  ) async {
    if (method == 'resources/read') {
      return request(requiredString(params, 'server'), method, {
        'uri': requiredString(params, 'uri'),
      }, cancellation, scope: scope, onInput: onInput, timeout: timeout, readOnly: readOnly);
    }
    final server = params['server'] as String?;
    if (server != null) {
      return request(server, method, {
        if (params['cursor'] != null) 'cursor': params['cursor'],
      }, cancellation, scope: scope);
    }
    if (params['cursor'] != null) {
      throw ArgumentError('A resource cursor requires its server name');
    }
    final key = method == 'resources/list' ? 'resources' : 'resourceTemplates';
    final values = <Json>[];
    final cursors = <String, String>{};
    for (final entry in _visible(scope).entries) {
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
    CancellationToken cancellation, {String? scope}
  ) => _subscribe(owner, params, cancellation, scope: scope);

  Future<Json> _subscribe(String owner, Json params, CancellationToken cancellation, {String? scope, Json? restored}) async {
    lifetime.throwIfCancelled();
    cancellation.throwIfCancelled();
    if (_subscriptions.values.where((v) => v.owner == owner).length >= 64 ||
        _subscriptions.length >= 256) {
      throw const McpFailure('MCP event subscription limit reached');
    }
    final server = requiredString(params, 'server');
    final target = _visible(scope)[server];
    if (target == null) throw ArgumentError('Unknown MCP server in this scope');
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
    late final McpEventSubscription subscription;
    subscription = McpEventSubscription(
      id: restored == null ? newId() : requiredString(restored, 'subscription_id'),
      owner: owner,
      server: server,
      name: name,
      arguments: jsonObject(params['arguments'] ?? {}),
      mode: mode,
      cursor: params['cursor'] as String?,
      maxAgeMs: params['max_age_ms'] as int?,
      ttlMs: params.containsKey('ttl_ms') ? params['ttl_ms'] as int? : 300000,
      publicUrl: publicUrl,
      threadId: params['threadId'] as String?,
      restoredCallback: restored?['callback'] as String?,
      restoredSecret: restored?['secret'] == null ? null : base64.decode(restored!['secret'] as String),
      restoredUpstreamId: restored?['upstream_id'] as String?,
      checkpoint: params['threadId'] == null ? null : (snapshot, token) async {
        if (persistSubscription == null) throw const McpFailure('Durable event subscriptions are unavailable', status: 503);
        await persistSubscription!('save', {'snapshot': snapshot}, token);
      },
      onTerminated: params['threadId'] == null ? null : (token) async {
        await persistSubscription?.call('remove', {'threadId': params['threadId'], 'subscription_id': subscription.id}, token);
      },
      acceptEvent: params['threadId'] == null ? null : (occurrence, snapshot, token) async {
        if (acceptThreadEvent == null) throw const McpFailure('Thread event delivery is unavailable', status: 503);
        await acceptThreadEvent!({'threadId': params['threadId'], 'subscription_id': subscription.id,
          'server': server, 'snapshot': snapshot, 'notification': {'method': 'notifications/events/event', 'params': occurrence}}, token);
      },
      connection: target.ready,
      onEvent: (event) =>
          onEvent(owner, {if (params['threadId'] != null) 'threadId': params['threadId'], ...event}),
    );
    _subscriptions[subscription.id] = subscription;
    _subscriptionTargets[subscription.id] = target;
    var admitted = false;
    try {
      if (subscription.threadId != null) {
        if (persistSubscription == null) throw const McpFailure('Durable event subscriptions are unavailable', status: 503);
        await persistSubscription!('save', {'snapshot': subscription.toSnapshot(), 'create': restored == null}, lifetime);
        admitted = true;
      }
      // Once desired thread state is durable, activation belongs to the host.
      // Losing the initiating caller only stops its wait, not the saved job.
      final activation = subscription.start(admitted ? lifetime : cancellation);
      if (admitted) unawaited(activation.then<void>((_) {}, onError: (Object _) {}));
      await activation.asCancellable(cancellation);
      return subscription.toJson();
    } catch (_) {
      if (!admitted) {
        await subscription.stop();
        _subscriptions.remove(subscription.id);
        _subscriptionTargets.remove(subscription.id);
      }
      rethrow;
    }
  }

  Future<void> restore(String threadId, List<Json> snapshots, CancellationToken cancellation, {String? scope}) async {
    for (final snapshot in snapshots) {
      cancellation.throwIfCancelled();
      try {
        final id = requiredString(snapshot, 'subscription_id');
        if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) || snapshot['threadId'] != threadId || _subscriptions.containsKey(id)) continue;
        await _subscribe('thread:$threadId', snapshot, cancellation, scope: scope, restored: snapshot);
      } on CancelledException { rethrow; }
      catch (_) { /* Retain desired state for a later startup/config repair. */ }
    }
  }

  List<Json> subscriptions(String owner) => _subscriptions.values
      .where((s) => s.owner == owner)
      .map((s) => s.toJson())
      .toList();

  Future<void> unsubscribe(String owner, String id, {bool persist = true}) async {
    final subscription = _subscriptions[id];
    if (subscription == null) {
      // A disabled/missing server may prevent an intent from materializing at
      // startup. It is still removable by its saved thread owner.
      if (persist && owner.startsWith('thread:')) {
        final threadId = owner.substring(7); validateTaskId(threadId);
        await persistSubscription?.call('remove', {'threadId': threadId, 'subscription_id': id}, lifetime);
      }
      return;
    }
    if (subscription.owner != owner) {
      throw ArgumentError('Subscription belongs to another client');
    }
    if (persist && subscription.threadId != null) await persistSubscription?.call('remove', {
      'threadId': subscription.threadId, 'subscription_id': id,
    }, lifetime);
    await subscription.stop();
    _subscriptions.remove(id);
    _subscriptionTargets.remove(id);
  }

  Future<void> detach(String owner, {bool persist = true}) async {
    await Future.wait(
      _subscriptions.values
          .where((s) => s.owner == owner)
          .toList()
          .map((s) => unsubscribe(owner, s.id, persist: persist)),
    );
  }

  Future<Json> webhook(String id, Json headers, List<int> body, CancellationToken cancellation) async {
    final subscription = _subscriptions[id];
    if (subscription == null) return {'status': 410};
    return subscription.webhook(headers, body, cancellation);
  }

  Future<void> close() async {
    lifetime.cancel();
    await _reload;
    await Future.wait(_subscriptions.values.toList().map((s) => s.stop(preserveRemote: s.threadId != null)));
    _subscriptions.clear();
    _subscriptionTargets.clear();
    for (final server in _bindings) { server.close(); }
    await Future.wait(_connections.map((connection) => connection.close()));
    _servers.clear();
    _localServers.clear(); _localConfigured.clear(); _connections.clear(); _processes.clear(); _catalogs.clear();
  }
}

class _Server {
  _Server(this.name, this.config, this.executableRevision, this.scope, this.shared);
  final String name;
  final Json config;
  final String? executableRevision;
  final String? scope;
  final _Connection shared;
  final lifetime = CancellationToken();
  Completer<void> get initial => shared.initial;
  McpConnection? get connection => shared.connection;
  McpOAuth? get oauth => shared.oauth;
  bool get _unsupported => config['legacy_fallback'] == false && shared.state == 'ready' && connection?.modern == false;
  String get state => _unsupported ? 'failed' : shared.state;
  String? get error => _unsupported ? 'MCP server does not support the required modern protocol' : shared.error;
  bool get authenticationRequired => shared.authenticationRequired;
  Map<String, Json>? _source;
  Map<String, Json> _tools = {};
  Map<String, Json> get tools {
    if (_unsupported) return const {};
    if (!identical(_source, shared.tools)) {
      _source = shared.tools;
      _tools = {for (final tool in shared.tools.values)
        'mcp__${_safeName(name)}__${_safeName(tool['name'] as String)}': tool};
    }
    return _tools;
  }
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

  Future<McpConnection> ready(CancellationToken cancellation) async {
    final connection = await shared.ready(cancellation.merge(lifetime));
    if (_unsupported) throw McpFailure(error!);
    return connection;
  }
  Future<Json> request(String method, Json params, CancellationToken cancellation, {Json? inputSchema, bool retrySafe = false,
    McpInputHandler? onInput, Duration? timeout = mcpToolTimeout, bool readOnly = false}) async {
    await ready(cancellation);
    return shared.request(method, params, cancellation.merge(lifetime), inputSchema: inputSchema, retrySafe: retrySafe,
      onInput: onInput, timeout: timeout, readOnly: readOnly);
  }
  Future<List<Json>> list(String method, String key, CancellationToken cancellation) async {
    await ready(cancellation);
    return shared.list(method, key, cancellation.merge(lifetime));
  }
  void close() => lifetime.cancel();
}

/// Physical ownership is independent of aliases, config scope and request waiters.
class _Connection {
  _Connection(this.config, this.http, this.oauth, this.onAuthChanged, this.clientCapabilities, this.requestMetadata);
  final Json clientCapabilities;
  final McpRequestMetadata? requestMetadata;
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

  void start() {
    _runner = _run();
  }

  Future<void> _run() async {
    var failures = 0;
    while (!lifetime.isCancelled && failures < 6) {
      final since = Stopwatch()..start();
      var credentialFailure = false;
      String? startupAccess;
      final current = McpConnection(config, http, _notification,
        authorization: oauth == null ? null : (token) async =>
          state == 'connecting' ? startupAccess : await oauth!.authorization(token),
        onAuthChallenge: oauth?.challenge, onRecover: oauth?.recover,
        clientCapabilities: clientCapabilities, requestMetadata: requestMetadata);
      connection = current;
      try {
        state = 'connecting';
        // OAuth preparation owns its own request deadline, before the MCP
        // handshake starts. One prepared token serves the complete handshake
        // and initial catalog, even when the provider reports zero lifetime.
        startupAccess = await oauth?.authorization(lifetime);
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
        credentialFailure = failure is McpCredentialFailure;
        authenticationRequired = failure is McpCredentialFailure ? failure.authenticationRequired
          : failure is McpFailure && (failure.status == 401 || failure.status == 403);
        error = authenticationRequired ? 'MCP server requires authentication' : 'MCP connection unavailable';
        if (authenticationRequired) onAuthChanged();
      } finally {
        await current.close();
        tools = {};
        if (!initial.isCompleted) initial.complete();
      }
      if (lifetime.isCancelled) break;
      if (authenticationRequired && (credentialFailure || oauth?.canRefresh != true)) { state = 'failed'; break; }
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
    bool retrySafe = false,
    McpInputHandler? onInput,
    Duration? timeout = mcpToolTimeout,
    bool readOnly = false,
  }) async {
    final current = await ready(cancellation);
    try {
      final result = await current.requestWithInput(
        method,
        params,
        cancellation: cancellation,
        inputSchema: inputSchema,
        retrySafe: retrySafe,
        onInput: onInput, timeout: timeout, readOnly: readOnly,
      );
      if (result['isError'] == true && result['_meta']?['mcp/www_authenticate'] != null) {
        authenticationRequired = true;
        error = 'MCP server requires authentication';
        onAuthChanged();
        // Refresh/reconnect may repair the shared owner for later user calls,
        // but the rejected tools/call has already completed and is never replayed.
        if (oauth?.canRefresh == true) { tools = {}; unawaited(current.close()); }
      } else if (authenticationRequired) {
        authenticationRequired = false; error = null; onAuthChanged();
      }
      return result;
    } on SocketException {
      unawaited(current.close());
      throw const McpFailure(
        'MCP transport disconnected; an interrupted call may have taken effect',
      );
    } on McpFailure catch (failure) {
      if (failure is McpCredentialFailure) {
        if (!failure.authenticationRequired) rethrow;
        authenticationRequired = true; error = 'MCP server requires authentication'; onAuthChanged();
        // No tool request left this process. Keep the original credentials and
        // catalog for an explicit later retry; do not start an automatic loop.
        if (method == 'tools/call') return {'isError': true,
          'content': [{'type': 'text', 'text': failure.message}],
          '_meta': {'mcp/www_authenticate': 'Bearer error="invalid_token"'}};
        rethrow;
      }
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
    // Bound the whole catalog, including each request's retries and backoff.
    // A fresh per-page deadline lets an individually timely server run forever.
    final deadline = TimeoutCancellationToken(mcpCatalogTimeout,
      timeoutException: TimeoutException('$method pagination timed out after 30s', mcpCatalogTimeout));
    final token = cancellation.merge(lifetime).merge(deadline);
    try {
      final result = <Json>[];
      final seen = <String>{};
      String? cursor;
      for (var page = 0; page < 20; page++) {
        final value = connecting
            ? await connection!.request(method, {
                'cursor': ?cursor,
              }, cancellation: token, timeout: null)
            : await request(method, {'cursor': ?cursor}, token, timeout: null);
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
    } finally { deadline.cancel(); }
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
      final callable = _safeName(requiredString(tool, 'name'));
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

Object? _ordered(Object? value) => switch (value) {
  Map() => {for (final key in value.keys.cast<String>().toList()..sort()) key: _ordered(value[key])},
  List() => value.map(_ordered).toList(),
  _ => value,
};
