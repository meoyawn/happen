import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:config/config.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';
import 'package:mcp/mcp.dart';
import 'package:telemetry/telemetry.dart';
import 'package:storage/src/codex_native.dart' show projectedCodexItem;

import 'agents_md.dart';
import 'skills.dart';
import 'mcp_executables.dart';

Future<IsolateOwner> startNetwork(
  String directory, {
  String? endpoint,
  String? apiKeyEnv,
  String? openCodeEndpoint,
  String? openCodeSearchEndpoint,
  String? publicUrl,
  String? configPath,
  String? skillsHome,
  SendPort? events,
}) async {
  configPath = File(configPath ?? defaultConfigPath()).absolute.path;
  // Validate before spawning so startup errors reach the caller with a field
  // path, instead of being reduced to an opaque isolate-startup failure.
  final global = await loadConfig(
    configPath,
    legacyPath: '$directory/config.json',
  );
  return IsolateOwner.start(_networkMain, {
    'directory': directory,
    'skills_home': skillsHome,
    'endpoint': endpoint,
    'api_key_env': apiKeyEnv,
    'opencode_endpoint': openCodeEndpoint,
    'opencode_search_endpoint': openCodeSearchEndpoint,
    'public_url': publicUrl,
    'config_path': configPath,
    'config': global.values,
    'loaded_config_path': global.path,
    'events': events,
  });
}
Future<void> _networkMain(List<Object?> args) async {
  final startup = jsonObject(args[1]);
  final directory = startup['directory'] as String;
  final configPath = startup['config_path'] as String;
  final global = jsonObject(startup['config']);
  var codeModeToolSearch = global['code_mode_tool_search'] as bool?;
  final http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30);
  final auth = AuthManager(directory, http: http);
  final consoleAuth = OpenCodeAuthManager(directory, http: http);
  final endpoint = startup['endpoint'];
  final lifetime = CancellationToken();
  final apiKeyEnv = startup['api_key_env'] as String?;
  if (apiKeyEnv != null && endpoint == null) throw ArgumentError('An API-key Responses endpoint is required');
  Future<Json> gptCredentials({bool refresh = false}) async {
    if (apiKeyEnv == null) return auth.credentials(refresh: refresh);
    final key = Platform.environment[apiKeyEnv];
    if (key != null && key.isNotEmpty) return {'access_token': key};
    final host = Uri.parse(endpoint as String).host;
    if (host == 'localhost' || (InternetAddress.tryParse(host)?.isLoopback ?? false)) return {};
    throw StateError('Responses API credential environment variable is missing');
  }
  final gptClient = ResponsesClient(
    http: http,
    credentials: gptCredentials,
    endpoint: endpoint == null ? null : Uri.parse(endpoint as String),
  );
  final gptCatalog = GptCatalog(gptClient, directory: directory, lifetime: lifetime);
  final gpt = OpenAIProvider(gptClient, catalog: gptCatalog);
  final searchEndpoint = startup['opencode_search_endpoint'] as String?;
  final deepseek = OpenCodeProvider.native(
    http: http,
    searchAuth: consoleAuth,
    openCodeSearchEndpoint: searchEndpoint == null ? null : Uri.parse(searchEndpoint),
    credentials: () async {
      final value = Platform.environment['DEEPSEEK_API_KEY'];
      if (value == null || value.isEmpty) throw StateError('DeepSeek credential environment variable is missing');
      return value;
    },
  );
  final openCodeEndpoint = startup['opencode_endpoint'] as String?;
  final opencode = OpenCodeProvider(
    http: http,
    auth: consoleAuth,
    searchAuth: consoleAuth,
    openCodeSearchEndpoint: searchEndpoint == null ? null : Uri.parse(searchEndpoint),
    endpoint: openCodeEndpoint == null ? null : Uri.parse(openCodeEndpoint),
  );
  final providers = <String, ModelProvider>{'openai': gpt, 'gpt': gpt, 'deepseek': deepseek, 'opencode': opencode};
  final active = <String, Map<String, CancellationToken>>{};
  final operations = <String, CancellationToken>{};
  final mcpLogins = <String, ({String owner, String id})>{};
  final repositoryInstructions = RepositoryInstructions();
  final skills = FilesystemSkills(homeDirectory: startup['skills_home'] as String?);
  String? loginId, loginOwner;
  CancellationToken? loginCancellation;
  final pending = <Future<void>>{};
  final mcp = McpManager(
    http: http,
    clientCapabilities: mcpInputCapabilities,
    // This host has no managed network sandbox/proxy policy. Report that fact
    // only to a peer which negotiated the policy metadata capability; callers
    // cannot replace this host-owned field or carry it across capability changes.
    requestMetadata: (capabilities) => {
      if (capabilities['experimental']?['codex/network-policy-meta'] != null)
        'codex/network-policy-meta': {'enabled': false},
    },
    directory: directory,
    onAuthChanged: (server) => (startup['events'] as SendPort?)?.send({
      'event': {'type': 'mcp.auth.changed', 'server': server},
    }),
    publicUrl: startup['public_url'] as String?,
    persistSubscription: (operation, params, cancellation) async {
      try {
        await callIsolate(startup['events'] as SendPort, 'mcp.subscription.$operation', params, cancellation: cancellation);
      } on CancelledException { rethrow; }
      catch (_) { throw const McpFailure('Unable to persist the thread event subscription', status: 503); }
    },
    acceptThreadEvent: (event, cancellation) async {
      try {
        await callIsolate(startup['events'] as SendPort, 'mcp.event.accept', {'event': event}, cancellation: cancellation);
      } on CancelledException { rethrow; }
      catch (_) { throw const McpFailure('Thread inbox is unavailable; retry this event', status: 503); }
    },
    onEvent: (owner, event) => (startup['events'] as SendPort?)?.send({
      'owner': owner,
      'event': event,
    }),
  );
  final startupServers = resolveMcpCwds(jsonObject(global['mcp_servers'] ?? {}),
    base: Directory.current.path, defaultCwd: Directory.current.path);
  final startupExecutables = await readMcpExecutables(startupServers, lifetime);
  Map<String, String> revisions(Map<String, McpExecutable> executables) => {
    for (final entry in executables.entries) entry.key: entry.value.revision,
  };
  String fingerprint(Json servers, Map<String, McpExecutable> executables) =>
      jsonEncode([servers, revisions(executables)]);
  final localCwds = <String>{}, localApplied = <String, String>{}, localErrors = <String, String>{};
  final localPaths = <String, List<String>>{}, localReaders = <String, ConfigReader>{};
  final localExecutables = <String, Map<String, McpExecutable>>{};
  var acceptedServers = startupServers, acceptedExecutables = startupExecutables;
  Iterable<String> watchedPaths(Map<String, McpExecutable> executables) => [
    configPath, '$directory/config.json',
    for (final executable in executables.values) ...executable.paths,
    for (final paths in localPaths.values) ...paths,
    for (final executables in localExecutables.values) for (final executable in executables.values) ...executable.paths,
  ];
  final initialized = mcp.configure(startupServers, lifetime,
    executableRevisions: revisions(startupExecutables));
  // Capture startup failure for callers without an unhandled background error.
  unawaited(initialized.catchError((Object _) {}));
  var closing = false;
  var loadedConfigPath = startup['loaded_config_path'] as String?;
  String? appliedMcp = fingerprint(startupServers, startupExecutables);
  String? configError;
  final configReader = ConfigReader();
  late final ConfigWatcher watcher;
  Future<void> reloads = initialized.catchError((Object _) {});
  void configEvent(String type, Json data) {
    if (closing) return;
    (startup['events'] as SendPort?)?.send({
      'event': {'type': type, 'data': data},
    });
  }

  Future<void> reloadLocal(String scope, CancellationToken cancellation) async {
    try {
      final paths = localPaths[scope] = await mcpConfigPaths(scope, cancellation);
      var local = <String, dynamic>{};
      for (final path in paths) {
        if (path == configPath) continue;
        final reader = localReaders.putIfAbsent(path, () => ConfigReader(partialMcp: true));
        final layer = await reader.load(path, cancellation: cancellation);
        local = mergeMcpConfig(local, resolveMcpCwds(jsonObject(layer.values['mcp_servers'] ?? {}), base: File(path).parent.path));
      }
      final servers = resolveMcpCwds({for (final name in local.keys)
        name: mergeMcpConfig(jsonObject(acceptedServers[name] ?? {}), jsonObject(local[name]))}, base: scope, defaultCwd: scope);
      parseConfig(jsonEncode({'mcp_servers': servers}));
      validateMcpServers(servers);
      final executables = await readMcpExecutables(servers, cancellation);
      final encoded = fingerprint(servers, executables);
      localExecutables[scope] = executables;
      watcher.updatePaths(watchedPaths(acceptedExecutables));
      if (encoded != localApplied[scope]) {
        localApplied.remove(scope);
        await mcp.configure(servers, cancellation, scope: scope, executableRevisions: revisions(executables));
        localApplied[scope] = encoded;
        configEvent('mcp.config.reloaded', {'cwd': scope, 'servers': mcp.status(scope: scope)});
      }
      localErrors.remove(scope);
    } on CancelledException { rethrow;
    } catch (error) {
      final message = error is FormatException ? error.message : 'Could not reload project MCP configuration';
      if (localErrors[scope] != message) {
        localErrors[scope] = message; configEvent('mcp.config.error', {'cwd': scope, 'error': message});
      }
      watcher.updatePaths(watchedPaths(acceptedExecutables));
      rethrow;
    }
  }

  Future<void> reload(CancellationToken cancellation, {String? cwd}) {
    if (cwd != null) localCwds.add(cwd);
    final next = reloads.then((_) async {
      cancellation.throwIfCancelled();
      lifetime.throwIfCancelled();
      Object? globalFailure;
      try {
        final updated = await configReader.load(
          configPath,
          // Once YAML has been selected, deleting it must not restore an old
          // legacy config during an editor's delete/rename save sequence.
          legacyPath: loadedConfigPath == configPath
              ? null
              : '$directory/config.json',
          cancellation: cancellation,
        );
        if (updated.path == null && loadedConfigPath != null) {
          throw const FormatException(
            'Configuration file is missing; keeping the running MCP servers',
          );
        }
        final servers = resolveMcpCwds(jsonObject(updated.values['mcp_servers'] ?? {}),
          base: Directory.current.path, defaultCwd: Directory.current.path);
        final executables = await readMcpExecutables(servers, cancellation);
        cancellation.throwIfCancelled();
        lifetime.throwIfCancelled();
        acceptedExecutables = executables;
        watcher.updatePaths(watchedPaths(executables));
        final encoded = fingerprint(servers, executables);
        final changed = encoded != appliedMcp;
        final recovered = configError != null;
        if (changed) {
          // Cancellation can interrupt process replacement. Force the next
          // reload to reconcile even if the file reverts to the previous value.
          appliedMcp = null;
          await mcp.configure(servers, cancellation,
            executableRevisions: revisions(executables));
        }
        cancellation.throwIfCancelled();
        lifetime.throwIfCancelled();
        appliedMcp = encoded;
        acceptedServers = servers;
        codeModeToolSearch = updated.values['code_mode_tool_search'] as bool?;
        loadedConfigPath = updated.path;
        configError = null;
        if (changed || recovered) {
          configEvent('mcp.config.reloaded', {'servers': mcp.status()});
        }
      } on CancelledException {
        rethrow;
      } catch (error) {
        final message = error is FormatException
            ? error.message
            : 'Could not reload MCP configuration';
        if (message != configError) {
          configError = message;
          configEvent('mcp.config.error', {'error': message});
        }
        globalFailure = error;
      }
      Object? localFailure;
      for (final scope in localCwds.toList()) {
        try { await reloadLocal(scope, cancellation); }
        on CancelledException { rethrow; }
        catch (error) { localFailure ??= error; }
      }
      if (globalFailure != null) Error.throwWithStackTrace(globalFailure, StackTrace.current);
      if (localFailure != null) Error.throwWithStackTrace(localFailure, StackTrace.current);
    });
    reloads = next.catchError((Object _) {});
    return next;
  }

  Future<void>? automaticReload;
  CancellationToken? automaticCancellation;
  var reloadAgain = false;
  void changed() {
    if (closing || lifetime.isCancelled) return;
    reloadAgain = true;
    automaticCancellation?.cancel();
    if (automaticReload != null) return;
    automaticReload = () async {
      do {
        reloadAgain = false;
        final cancellation = automaticCancellation = CancellationToken();
        try {
          await reload(cancellation.merge(lifetime));
        } on CancelledException {
          // A newer file change or shutdown superseded this reload.
        } catch (_) {
          // The sanitized failure was delivered through mcp.config.error.
        } finally {
          cancellation.cancel();
          automaticCancellation = null;
        }
      } while (reloadAgain && !lifetime.isCancelled);
    }().whenComplete(() => automaticReload = null);
  }

  watcher = ConfigWatcher(
    watchedPaths(startupExecutables),
    onChange: changed,
    cancellation: lifetime,
  );
  final port = ReceivePort();
  (args[0] as SendPort).send(port.sendPort);
  Future<void> handle(Json request) async {
    final params = jsonObject(request['params']);
    final reply = request['reply'] as SendPort?;
    final id = params['task_id'] as String?;
    CancellationToken? cancellation;
    final operationId = request['operation_id'] as String? ?? newId();
    // task_id selects saved cwd/context for public MCP calls; it does not give
    // a short-lived inference agent authority to cancel that client's request.
    final clientMcp = (request['method'] as String).startsWith('mcp.') && params['owner'] is String;
    final ownerId = clientMcp ? 'client:${params['owner']}' : id ?? 'client:${params['owner'] ?? 'server'}';
    try {
      if (request['method'] == 'cancel') {
        if (params['operation_id'] is String) {
          operations[params['operation_id']]?.cancel();
        } else {
          for (final token
              in active[id]?.values.toList() ?? <CancellationToken>[]) {
            token.cancel();
          }
        }
        reply?.send({'result': null});
        return;
      }
      if (closing) throw StateError('Network owner is shutting down');
      cancellation = CancellationToken();
      operations[operationId] = cancellation;
      active.putIfAbsent(ownerId, () => {})[operationId] = cancellation;
      if ({'skills.search', 'skills.catalog', 'skills.read'}.contains(request['method'])) {
        final provider = providers[params['provider'] as String? ?? 'openai'];
        if (provider == null) throw ArgumentError('Unsupported skills provider');
        final roots = provider.additionalUserSkillRoots;
        if (request['method'] == 'skills.search') {
          reply?.send({'result': await skills.search(params, cancellation, additionalUserRoots: roots)});
          return;
        }
        if (id == null) throw ArgumentError('Skills require a task');
        final cwd = requiredString(params, 'cwd');
        reply?.send({'result': request['method'] == 'skills.catalog'
          ? await skills.catalog(cwd, cancellation, additionalUserRoots: roots)
          : await skills.read(cwd, requiredString(params, 'id'), cancellation, additionalUserRoots: roots)});
        return;
      }
      if (request['method'] == 'agents.repository') {
        if (id == null) throw ArgumentError('Repository instructions require a task');
        reply?.send({'result': await repositoryInstructions.load(
          id, requiredString(params, 'cwd'), cancellation,
        )});
        return;
      }
      if (request['method'] == 'agents.forget') {
        if (id == null) throw ArgumentError('Repository instructions require a task');
        repositoryInstructions.forget(id);
        reply?.send({'result': null});
        return;
      }
      if (request['method'] == 'auth.desktop') {
        if (loginCancellation != null) throw StateError('Finish signing in before starting dictation');
        try {
          final credentials = await auth.credentials(refresh: params['refresh'] == true).asCancellable(cancellation);
          cancellation.throwIfCancelled();
          reply?.send({'result': credentials});
        } on CancelledException {
          rethrow;
        } catch (_) {
          // Malformed credential files and provider replies can contain secrets.
          throw StateError('Sign in to ChatGPT on this computer to use dictation');
        }
        return;
      }
      if (request['method'] == 'auth.cancel') {
        if (loginId == params['login_id'] && loginOwner == params['owner']) {
          loginCancellation?.cancel();
        }
        reply?.send({'result': null});
        return;
      }
      if (request['method'] == 'auth.login') {
        final requestedProvider = requiredString(params, 'provider');
        final provider = requestedProvider == 'gpt' ? 'openai' : requestedProvider;
        if (provider != 'openai' && provider != 'opencode') {
          throw ArgumentError('Browser sign-in is unavailable for this provider');
        }
        if (loginCancellation != null) {
          throw StateError('A sign-in is already in progress');
        }
        loginId = requiredString(params, 'login_id');
        loginOwner = requiredString(params, 'owner');
        loginCancellation = cancellation;
        try {
          void notify(String url, String message, {String? code}) => reply?.send({
              'event': {
                'type': 'auth.login',
                'login_id': loginId,
                'provider': provider,
                'url': url,
                'message': message,
                'code': ?code,
              },
            });
          if (provider == 'openai') {
            gptCatalog.invalidate();
            (startup['events'] as SendPort?)?.send({'event': {'type': 'auth.changed', 'provider': 'openai'}});
            await auth.login(cancellation: cancellation, notify: notify);
          } else {
            await consoleAuth.login(
              cancellation: cancellation,
              notify: (url, code) => notify(url, 'Approve access in your browser.', code: code),
            );
          }
          reply?.send({
            'result': {'status': provider == 'openai' ? await auth.status() : await consoleAuth.status()},
          });
        } finally {
          loginCancellation = null;
          loginOwner = null;
          loginId = null;
        }
        return;
      }
      if (request['method'] == 'auth.logout') {
        final requestedProvider = requiredString(params, 'provider');
        final provider = requestedProvider == 'gpt' ? 'openai' : requestedProvider;
        if (provider == 'openai') {
          gptCatalog.invalidate();
          (startup['events'] as SendPort?)?.send({'event': {'type': 'auth.changed', 'provider': 'openai'}});
          await auth.signOut();
        } else if (provider == 'opencode') {
          await consoleAuth.signOut();
        } else {
          throw ArgumentError('This provider uses an environment API key');
        }
        reply?.send({'result': {'status': 'signed_out'}});
        return;
      }
      if ((request['method'] as String).startsWith('mcp.')) {
        await initialized.asCancellable(cancellation);
        final cwd = params['cwd'] as String?;
        final scope = cwd == null ? null : Directory(cwd).absolute.uri.normalizePath().toFilePath();
        if (scope != null && !localCwds.contains(scope)) {
          try { await reload(cancellation, cwd: scope); }
          on CancelledException { rethrow; }
          catch (_) { /* Retain the last accepted config, including on first discovery. */ }
        }
        final Object? result;
        final McpInputHandler? input = id == null && params['owner'] == null ? null : (inputId, inputRequest, token) async =>
          jsonObject(await callIsolate(startup['events'] as SendPort, 'mcp.input', {
            'request_id': inputId, 'threadId': id, 'owner': params['owner'], 'source': params['server'] ?? params['name'] ?? 'MCP',
            'request': inputRequest,
          }, cancellation: token));
        if (params['read_only'] != null && params['read_only'] is! bool) throw const FormatException('Expected read_only boolean');
        switch (request['method']) {
          case 'mcp.auth.login':
            final name = requiredString(params, 'server');
            final key = jsonEncode([scope, name]);
            final login = requiredString(params, 'login_id');
            if (mcpLogins.containsKey(key)) throw StateError('An MCP sign-in is already in progress');
            mcpLogins[key] = (owner: requiredString(params, 'owner'), id: login);
            try {
              final signingIn = mcp.login(name, cancellation, (url) => reply?.send({'event': {
                'type': 'mcp.auth.login', 'server': name, 'login_id': login, 'url': url,
              }}), scope: scope);
              configEvent('mcp.auth.changed', {'server': name});
              result = await signingIn;
            } finally {
              mcpLogins.remove(key);
              configEvent('mcp.auth.changed', {'server': name});
            }
          case 'mcp.auth.callback':
            final name = requiredString(params, 'server');
            final login = mcpLogins[jsonEncode([scope, name])];
            if (login == null || login.owner != params['owner'] || login.id != params['login_id']) {
              throw StateError('No matching MCP sign-in is waiting for a callback');
            }
            mcp.completeLogin(name, requiredString(params, 'callback_url'), scope: scope);
            result = null;
          case 'mcp.auth.logout':
            final name = requiredString(params, 'server');
            await mcp.logout(name, cancellation, scope: scope);
            configEvent('mcp.auth.changed', {'server': name});
            result = null;
          case 'mcp.status':
            result = mcp.status(scope: scope);
          case 'mcp.inventory':
            if (params['verbose'] != null && params['verbose'] is! bool ||
                params['server'] != null && params['server'] is! String) {
              throw const FormatException('Expected verbose boolean and optional server name');
            }
            try {
              await reload(cancellation, cwd: scope);
            } on CancelledException {
              rethrow;
            } catch (_) {
              // Keep the last accepted configuration and its live connections.
            }
            result = {
              ...await mcp.inventory(cancellation, verbose: params['verbose'] == true, server: params['server'] as String?, scope: scope),
              'config_error': ?(localErrors[scope] ?? configError),
            };
          case 'mcp.catalog':
            // A model step can follow a config edit before the watcher fires.
            // Read and serialize reconciliation here as well as on file events.
            if (params['revalidate'] != false) {
              try {
                await reload(cancellation, cwd: scope);
              } on CancelledException {
                rethrow;
              } catch (_) {
                // reload already sent a sanitized diagnostic; use the live catalog.
              }
            }
            result = await mcp.catalog(cancellation, knownRevision: params['revision'] as String?, scope: scope);
          case 'mcp.call':
            result = await mcp.callTool(
              requiredString(params, 'name'),
              params['arguments'],
              cancellation, scope: scope, onInput: input, readOnly: params['read_only'] == true,
            );
          case 'mcp.resources':
            result = await mcp.resources(
              requiredString(params, 'method'),
              jsonObject(params['arguments']),
              cancellation, scope: scope, onInput: input, readOnly: params['read_only'] == true,
            );
          case 'mcp.request':
            final method = requiredString(params, 'method');
            if (!{
              'events/list',
              'events/poll',
              'tools/list',
              'tools/call',
              'resources/list',
              'resources/templates/list',
              'resources/read',
              'prompts/list',
              'prompts/get',
            }.contains(method)) {
              throw ArgumentError('Unsupported public MCP request');
            }
            result = await mcp.request(
              requiredString(params, 'server'),
              method,
              jsonObject(params['arguments'] ?? {}),
              cancellation, scope: scope, onInput: input, readOnly: params['read_only'] == true,
            );
          case 'mcp.events.subscribe':
            result = await mcp.subscribe(
              requiredString(params, 'owner'),
              params,
              cancellation, scope: scope,
            );
          case 'mcp.events.restore':
            await mcp.restore(requiredString(params, 'threadId'), (params['subscriptions'] as List).map(jsonObject).toList(), cancellation, scope: scope);
            result = null;
          case 'mcp.events.unsubscribe':
            await mcp.unsubscribe(
              requiredString(params, 'owner'),
              requiredString(params, 'subscription_id'),
            );
            result = null;
          case 'mcp.events.subscriptions':
            result = mcp.subscriptions(requiredString(params, 'owner'));
          case 'mcp.detach':
            final owner = requiredString(params, 'owner');
            for (final token
                in active['client:$owner']?.values.toList() ??
                    <CancellationToken>[]) {
              if (!identical(token, cancellation)) token.cancel();
            }
            await mcp.detach(owner, persist: params['persist'] != false);
            result = null;
          case 'mcp.webhook':
            result = await mcp.webhook(
              requiredString(params, 'subscription_id'),
              jsonObject(params['headers']),
              (params['body'] as List).cast<int>(),
              cancellation,
            );
          case 'mcp.reload':
            await reload(cancellation, cwd: scope);
            result = mcp.status(scope: scope);
          default:
            throw StateError('Unknown MCP operation');
        }
        reply?.send({'result': result});
        return;
      }
      if (request['method'] == 'providers.list') {
        await gptCatalog.refresh(cancellation);
        reply?.send({
          'result': {
            'default_provider': 'openai',
            'providers': [
              {
                'id': 'openai',
                'name': 'ChatGPT',
                'auth': 'chatgpt',
                'status': await auth.status(),
                'default_model': gpt.defaultModel,
                'models': [
                  for (final model in supportedGptModels)
                    {
                      'id': model,
                      'name': gpt.modelInfo(model).data['display_name'] ?? model,
                      'reasoning_levels': gpt.modelInfo(model).reasoningLevels,
                      'default_reasoning': gpt.modelInfo(model).defaultReasoning,
                      'reasoning_updates': gpt.modelInfo(model).reasoningUpdates,
                      'input_modalities': gpt.modelInfo(model).data['input_modalities'],
                      'context_limit': gpt.modelInfo(model).usableContextWindow(),
                    },
                ],
              },
              {
                'id': 'opencode',
                'name': 'OpenCode',
                'auth': 'opencode',
                'status': await consoleAuth.status(),
                'default_model': opencode.defaultModel,
                'models': [{
                  'id': opencode.defaultModel,
                  'name': deepseekModel(opencode.defaultModel)['name'],
                  'reasoning_levels': ['off', 'low', 'high', 'max'],
                  'default_reasoning': opencode.resolveSettings({})['reasoning'],
                  'reasoning_updates': false,
                  'input_modalities': ['text', 'image'],
                }],
              },
            ],
          },
        });
        return;
      }
      if (request['method'] == 'configure') {
        final modelInput = params['model'] as String?;
        final selectedProvider =
            params['provider'] as String? ??
            (modelInput == openCodeDeepSeekModel
                ? 'opencode'
                : modelInput?.startsWith('deepseek') == true
                ? 'deepseek'
                : 'openai');
        final lab = selectedProvider == 'gpt' ? 'openai' : selectedProvider;
        final provider = providers[lab];
        if (provider == null) throw ArgumentError('Unsupported provider');
        if (lab == 'openai') await gptCatalog.refresh(cancellation);
        final model =
            modelInput ??
            (provider is OpenCodeProvider ? provider.defaultModel : gpt.defaultModel);
        final selected = {
          if (lab == 'openai' && codeModeToolSearch != null) 'code_mode_tool_search': codeModeToolSearch,
          ...jsonObject(params['settings'] ?? {}),
          if (params['reasoning'] != null) 'reasoning': params['reasoning'],
        };
        final settings = provider.resolveSettings(selected, model: model);
        if (lab == 'openai' && settings['image_generation'] == true) {
          try {
            final credentials = await gptCredentials().asCancellable(cancellation);
            if (credentials['plan_type'] == 'free') settings['image_generation'] = false;
          } on CancelledException { rethrow; }
          catch (_) { settings['image_generation'] = false; }
        }
        final info = lab == 'openai' ? gpt.modelInfo(model) : null;
        // PersistentModeState is separate developer context in Codex, enabled
        // only for persistent reasoning. This runtime does not offer that mode.
        final base = info?.instructions ?? deepseekInstructions(model);
        reply?.send({
          'result': {
            'provider': lab,
            'model': model,
            if (info != null) 'model_info': info.data,
            'provider_settings': settings,
            'instructions': base,
            'reasoning_updates': info?.reasoningUpdates ?? false,
            'catalog_revision': lab == 'openai'
                ? gptCatalog.revision
                : (provider as OpenCodeProvider).catalogRevision,
          },
        });
        return;
      }
      if (request['method'] == 'task.new_id') {
        final provider = providers[params['provider'] as String? ?? 'openai'];
        if (provider == null) throw ArgumentError('Unsupported provider');
        reply?.send({'result': provider.newTaskId()});
        return;
      }
      if (request['method'] == 'validate_settings') {
        final lab = requiredString(params, 'provider');
        final provider = providers[lab];
        if (provider == null) throw ArgumentError('Unsupported provider');
        final settings = provider is OpenAIProvider
          ? provider.resolveSettings(jsonObject(params['settings']), model: requiredString(params, 'model'),
            modelInfo: params['model_info'] == null ? null : jsonObject(params['model_info']))
          : provider.resolveSettings(jsonObject(params['settings']), model: requiredString(params, 'model'));
        reply?.send({'result': settings});
        return;
      }
      if (!{'respond', 'compact', 'web.search', 'image.generate'}.contains(request['method'])) {
        throw StateError('Unknown network operation');
      }
      final lab = requiredString(params, 'provider');
      final provider = providers[lab];
      if (provider == null) throw ArgumentError('Unsupported provider');
      if (id == null) throw ArgumentError('Model request requires a task');
      final input = ModelRequest.fromJson(params);
      void onEvent(Json event) {
        // Compaction reports progress through compaction.started and its durable
        // checkpoint. Its internal summary/reasoning is not an assistant reply.
        if (request['method'] == 'compact' &&
            {'text.delta', 'reasoning.delta'}.contains(event['type'])) {
          return;
        }
        reply?.send({'event': event});
      }
      final Object? result;
      Future<void> onNativeItem(String phase, Json item) async => reply?.send({'event': {
        'type': 'native.item.$phase', 'data': {
          'turnId': params['turn_id'], 'item': projectedCodexItem(item), 'canonicalItem': item,
          if (phase == 'completed') 'completedAtMs': DateTime.now().millisecondsSinceEpoch,
        },
      }});
      if (request['method'] == 'web.search') {
        result = await provider.webSearch(input, jsonObject(params['commands']), cancellation: cancellation,
          callId: requiredString(params, 'call_id'), onItem: onNativeItem);
      } else if (request['method'] == 'image.generate') {
        if (provider is! OpenAIProvider) throw ArgumentError('Provider does not support image generation');
        result = await provider.generateImage(input, jsonObject(params['arguments']), outputRoot: directory,
          callId: requiredString(params, 'call_id'), turnId: requiredString(params, 'turn_id'), cancellation: cancellation,
          onItem: onNativeItem);
      } else if (request['method'] == 'compact') {
        result = (await provider.compact(
          input,
          cancellation: cancellation,
          onEvent: onEvent,
        )).toJson();
      } else if (provider is OpenAIProvider) {
        result = (await provider.respond(input, cancellation: cancellation, onEvent: onEvent,
          onRecovery: (item) async {
            final acknowledgement = ReceivePort();
            try {
              if (reply == null) throw StateError('Content recovery requires a host');
              // The ordinary ordered event channel is also used for completed
              // output, so the agent commits those items before this guidance.
              reply.send({'event': {'type': 'model.recovery', 'item': item.toJson(), 'ack': acknowledgement.sendPort}});
              final admitted = jsonObject(await acknowledgement.first.asCancellable(cancellation));
              if (admitted['error'] != null) throw const ModelFailure('recovery_failed', 'Unable to persist content-filter guidance');
            } finally { acknowledgement.close(); }
          })).toJson();
      } else {
        result = (await provider.respond(
          input,
          cancellation: cancellation,
          onEvent: onEvent,
        )).toJson();
      }
      reply?.send({'result': result});
    } catch (error) {
      traceError(error);
      reply?.send({
        'error': error.toString(),
        if (error is ModelFailure) 'code': error.code,
        if (error is CancelledException) 'code': 'cancelled',
      });
    } finally {
      operations.remove(operationId);
      active[ownerId]?.remove(operationId);
      if (active[ownerId]?.isEmpty == true) active.remove(ownerId);
      cancellation?.cancel();
    }
  }

  port.listen((raw) async {
    final request = jsonObject(raw);
    if (request['method'] == 'close') {
      closing = true;
      try {
        lifetime.cancel();
        for (final token in operations.values.toList()) {
          token.cancel();
        }
        await watcher.close();
        await automaticReload;
        await reloads;
        await mcp.close();
        auth.close();
        consoleAuth.close();
        http.close(force: true);
        await Future.wait(pending.toList());
        (request['reply'] as SendPort).send({'result': null});
      } catch (_) {
        (request['reply'] as SendPort).send({
          'error': 'Network owner shutdown failed',
        });
      } finally {
        port.close();
        Isolate.exit();
      }
    }
    final operation = traceIncoming(request, () => handle(request),
      service: {'respond', 'compact', 'web.search', 'image.generate'}.contains(request['method']) &&
        request['params']?['provider'] == 'openai' ? 'openai' : 'network');
    pending.add(operation);
    unawaited(operation.whenComplete(() => pending.remove(operation)));
  });
}
