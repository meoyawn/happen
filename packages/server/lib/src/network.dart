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

import 'agents_md.dart';

Future<IsolateOwner> startNetwork(
  String directory, {
  String? endpoint,
  String? configPath,
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
    'endpoint': endpoint,
    'config_path': configPath,
    'config': global.values,
    'loaded_config_path': global.path,
    'events': events,
  });
}

void _networkMain(List<Object?> args) async {
  final startup = jsonObject(args[1]);
  final directory = startup['directory'] as String;
  final configPath = startup['config_path'] as String;
  final global = jsonObject(startup['config']);
  final providerOptions = jsonObject(global['providers'] ?? {});
  final gptOptions = jsonObject(providerOptions['openai'] ?? providerOptions['gpt'] ?? {});
  final deepseekOptions = jsonObject(providerOptions['deepseek'] ?? {});
  final deepseekSearch = jsonObject(deepseekOptions['web_search'] ?? {});
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final auth = AuthManager(directory, http: http);
  final consoleAuth = OpenCodeAuthManager(directory, http: http);
  final endpoint = startup['endpoint'] ?? gptOptions['endpoint'];
  final gpt = OpenAIProvider(
    ResponsesClient(
      http: http,
      credentials: auth.credentials,
      endpoint: endpoint == null ? null : Uri.parse(endpoint as String),
    ),
  );
  final backend = deepseekOptions['backend'] as String? ?? 'native';
  if (!{'native', 'opencode'}.contains(backend)) {
    throw ArgumentError('DeepSeek backend must be native or opencode');
  }
  final deepseekEndpoint = deepseekOptions['endpoint'] == null
      ? null
      : Uri.parse(deepseekOptions['endpoint'] as String);
  final deepseek = backend == 'opencode'
      ? OpenCodeProvider(
          http: http,
          auth: consoleAuth,
          endpoint: deepseekEndpoint,
          searchAuth: consoleAuth,
          openCodeSearchEndpoint: deepseekSearch['endpoint'] == null ? null : Uri.parse(deepseekSearch['endpoint'] as String),
        )
      : OpenCodeProvider.native(
          http: http,
          searchAuth: consoleAuth,
          openCodeSearchEndpoint: deepseekSearch['endpoint'] == null ? null : Uri.parse(deepseekSearch['endpoint'] as String),
          credentials: () async {
            final variable =
                deepseekOptions['api_key_env'] as String? ?? 'DEEPSEEK_API_KEY';
            final value = Platform.environment[variable];
            if (value == null || value.isEmpty) {
              throw StateError(
                'DeepSeek credential environment variable is missing',
              );
            }
            return value;
          },
          endpoint: deepseekEndpoint,
          transport: deepseekOptions['transport'] as String? ?? 'messages',
        );
  final openCodeOptions = jsonObject(providerOptions['opencode'] ??
      (backend == 'opencode' ? deepseekOptions : <String, dynamic>{}));
  final openCodeSearch = jsonObject(openCodeOptions['web_search'] ?? {});
  final opencode = OpenCodeProvider(
    http: http,
    auth: consoleAuth,
    searchAuth: consoleAuth,
    openCodeSearchEndpoint: openCodeSearch['endpoint'] == null ? null : Uri.parse(openCodeSearch['endpoint'] as String),
    endpoint: openCodeOptions['endpoint'] == null
        ? null : Uri.parse(openCodeOptions['endpoint'] as String),
  );
  final providers = <String, ModelProvider>{'openai': gpt, 'gpt': gpt, 'deepseek': deepseek, 'opencode': opencode};
  final active = <String, Map<String, CancellationToken>>{};
  final operations = <String, CancellationToken>{};
  final repositoryInstructions = RepositoryInstructions();
  String? loginId, loginOwner;
  CancellationToken? loginCancellation;
  final pending = <Future<void>>{};
  final lifetime = CancellationToken();
  final mcp = McpManager(
    http: http,
    publicUrl: global['public_url'] as String?,
    onEvent: (owner, event) => (startup['events'] as SendPort?)?.send({
      'owner': owner,
      'event': event,
    }),
  );
  final initialized = mcp.configure(
    jsonObject(global['mcp_servers'] ?? {}),
    lifetime,
  );
  // Capture startup failure for callers without an unhandled background error.
  unawaited(initialized.catchError((Object _) {}));
  var closing = false;
  var loadedConfigPath = startup['loaded_config_path'] as String?;
  String? appliedMcp = jsonEncode(global['mcp_servers'] ?? {});
  String? configError;
  Future<void> reloads = initialized.catchError((Object _) {});
  void configEvent(String type, Json data) {
    if (closing) return;
    (startup['events'] as SendPort?)?.send({
      'event': {'type': type, 'data': data},
    });
  }

  Future<void> reload(CancellationToken cancellation) {
    final next = reloads.then((_) async {
      cancellation.throwIfCancelled();
      lifetime.throwIfCancelled();
      try {
        final updated = await loadConfig(
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
        final servers = jsonObject(updated.values['mcp_servers'] ?? {});
        final encoded = jsonEncode(servers);
        final changed = encoded != appliedMcp;
        final recovered = configError != null;
        if (changed) {
          // Cancellation can interrupt process replacement. Force the next
          // reload to reconcile even if the file reverts to the previous value.
          appliedMcp = null;
          await mcp.configure(servers, cancellation);
        }
        cancellation.throwIfCancelled();
        lifetime.throwIfCancelled();
        appliedMcp = encoded;
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
        rethrow;
      }
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

  final watcher = ConfigWatcher(
    [configPath, '$directory/config.json'],
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
    final ownerId = id ?? 'client:${params['owner'] ?? 'server'}';
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
        if (provider != 'openai' && provider != 'opencode' && !(provider == 'deepseek' && backend == 'opencode')) {
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
          (startup['events'] as SendPort?)?.send({'event': {'type': 'auth.changed', 'provider': 'openai'}});
          await auth.signOut();
        } else if (provider == 'opencode' || provider == 'deepseek' && backend == 'opencode') {
          await consoleAuth.signOut();
        } else {
          throw ArgumentError('This provider uses an environment API key');
        }
        reply?.send({'result': {'status': 'signed_out'}});
        return;
      }
      if ((request['method'] as String).startsWith('mcp.')) {
        await initialized.asCancellable(cancellation);
        final Object? result;
        switch (request['method']) {
          case 'mcp.status':
            result = mcp.status();
          case 'mcp.inventory':
            if (params['verbose'] != null && params['verbose'] is! bool ||
                params['server'] != null && params['server'] is! String) {
              throw const FormatException('Expected verbose boolean and optional server name');
            }
            try {
              await reload(cancellation);
            } on CancelledException {
              rethrow;
            } catch (_) {
              // Keep the last accepted configuration and its live connections.
            }
            result = {
              ...await mcp.inventory(cancellation, verbose: params['verbose'] == true, server: params['server'] as String?),
              'config_error': ?configError,
            };
          case 'mcp.catalog':
            // A model step can follow a config edit before the watcher fires.
            // Read and serialize reconciliation here as well as on file events.
            try {
              await reload(cancellation);
            } on CancelledException {
              rethrow;
            } catch (_) {
              // reload already sent a sanitized diagnostic; use the live catalog.
            }
            result = await mcp.catalog(cancellation, knownRevision: params['revision'] as String?);
          case 'mcp.call':
            result = await mcp.callTool(
              requiredString(params, 'name'),
              params['arguments'],
              cancellation,
            );
          case 'mcp.resources':
            result = await mcp.resources(
              requiredString(params, 'method'),
              jsonObject(params['arguments']),
              cancellation,
            );
          case 'mcp.request':
            final method = requiredString(params, 'method');
            if (!{
              'events/list',
              'events/poll',
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
              cancellation,
            );
          case 'mcp.events.subscribe':
            result = await mcp.subscribe(
              requiredString(params, 'owner'),
              params,
              cancellation,
            );
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
            await mcp.detach(owner);
            result = null;
          case 'mcp.webhook':
            result = mcp.webhook(
              requiredString(params, 'subscription_id'),
              jsonObject(params['headers']),
              (params['body'] as List).cast<int>(),
            );
          case 'mcp.reload':
            await reload(cancellation);
            result = mcp.status();
          default:
            throw StateError('Unknown MCP operation');
        }
        reply?.send({'result': result});
        return;
      }
      if (request['method'] == 'providers.list') {
        reply?.send({
          'result': {
            'default_provider': global['default_provider'] == 'gpt' ? 'openai' : global['default_provider'] ?? 'openai',
            'providers': [
              {
                'id': 'openai',
                'name': 'ChatGPT',
                'auth': 'chatgpt',
                'status': await auth.status(),
                'default_model': gptOptions['model'] ?? 'gpt-6.1-sol',
                'models': [
                  for (final model in supportedGptModels)
                    {
                      'id': model,
                      'name': GptModel(model).data['display_name'] ?? model,
                      'reasoning_levels': GptModel(model).reasoningLevels,
                      'default_reasoning':
                          GptModel(model).reasoningLevels
                              .contains(gptOptions['settings']?['reasoning'])
                          ? gptOptions['settings']['reasoning']
                          : GptModel(model).defaultReasoning,
                      'reasoning_updates': GptModel(model).reasoningUpdates,
                      'input_modalities': ['text', 'image'],
                    },
                ],
              },
              {
                'id': 'opencode',
                'name': 'OpenCode',
                'auth': 'opencode',
                'status': await consoleAuth.status(),
                'default_model': openCodeOptions['model'] ?? opencode.defaultModel,
                'models': [{
                  'id': opencode.defaultModel,
                  'name': deepseekModel(opencode.defaultModel)['name'],
                  'reasoning_levels': ['off', 'low', 'high', 'max'],
                  'default_reasoning': opencode.resolveSettings(jsonObject(openCodeOptions['settings'] ?? {}))['reasoning'],
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
                : global['default_provider'] as String? ?? 'openai');
        final lab = selectedProvider == 'gpt' ? 'openai' : selectedProvider;
        final provider = providers[lab];
        if (provider == null) throw ArgumentError('Unsupported provider');
        final defaults = lab == 'openai' ? gptOptions : lab == 'opencode' ? openCodeOptions : jsonObject(providerOptions[lab] ?? {});
        final model =
            modelInput ??
            defaults['model'] as String? ??
            (provider is OpenCodeProvider ? provider.defaultModel : 'gpt-6.1-sol');
        final selected = {
          ...jsonObject(defaults['settings'] ?? {}),
          ...jsonObject(params['settings'] ?? {}),
          if (params['reasoning'] != null) 'reasoning': params['reasoning'],
        };
        final settings = provider.resolveSettings(selected, model: model);
        final info = lab == 'openai' ? GptModel(model) : null;
        final base = info == null
            ? deepseekInstructions(model)
            : [
                info.instructions,
                info.persistentInstructions,
              ].where((s) => s.isNotEmpty).join('\n\n');
        reply?.send({
          'result': {
            'provider': lab,
            'model': model,
            'provider_settings': settings,
            'base_instructions': base,
            'reasoning_updates': info?.reasoningUpdates ?? false,
            'catalog_revision': lab == 'openai'
                ? gptCatalogRevision
                : (provider as OpenCodeProvider).catalogRevision,
          },
        });
        return;
      }
      if (request['method'] == 'validate_settings') {
        final lab = requiredString(params, 'provider');
        final provider = providers[lab];
        if (provider == null) throw ArgumentError('Unsupported provider');
        final settings = provider.resolveSettings(
          jsonObject(params['settings']),
          model: requiredString(params, 'model'),
        );
        reply?.send({'result': settings});
        return;
      }
      if (!{'respond', 'compact', 'web.search'}.contains(request['method'])) {
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
      if (request['method'] == 'web.search') {
        result = await provider.webSearch(input, jsonObject(params['commands']), cancellation: cancellation);
      } else if (request['method'] == 'compact') {
        result = (await provider.compact(
          input,
          cancellation: cancellation,
          onEvent: onEvent,
        )).toJson();
      } else {
        result = (await provider.respond(
          input,
          cancellation: cancellation,
          onEvent: onEvent,
        )).toJson();
      }
      reply?.send({'result': result});
    } catch (error) {
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
    final operation = handle(request);
    pending.add(operation);
    unawaited(operation.whenComplete(() => pending.remove(operation)));
  });
}
