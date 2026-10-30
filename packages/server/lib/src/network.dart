import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:gpt/gpt.dart';
import 'package:deepseek/deepseek.dart';
import 'package:protocol/protocol.dart';
import 'package:mcp/mcp.dart';

Future<IsolateOwner> startNetwork(
  String directory, {
  String? endpoint,
  SendPort? events,
}) => IsolateOwner.start(_networkMain, {
  'directory': directory,
  'endpoint': endpoint,
  'events': events,
});

void _networkMain(List<Object?> args) async {
  final startup = jsonObject(args[1]);
  final directory = startup['directory'] as String;
  final file = File('$directory/config.json');
  final global = await file.exists()
      ? jsonObject(jsonDecode(await file.readAsString()))
      : <String, dynamic>{};
  final providerOptions = jsonObject(global['providers'] ?? {});
  final gptOptions = jsonObject(providerOptions['gpt'] ?? {});
  final deepseekOptions = jsonObject(providerOptions['deepseek'] ?? {});
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final auth = AuthManager(directory, http: http);
  final consoleAuth = OpenCodeAuthManager(directory, http: http);
  final endpoint = startup['endpoint'] ?? gptOptions['endpoint'];
  final gpt = GptProvider(
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
      ? DeepSeekProvider.opencode(
          http: http,
          auth: consoleAuth,
          endpoint: deepseekEndpoint,
        )
      : DeepSeekProvider(
          http: http,
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
  final providers = <String, ModelProvider>{'gpt': gpt, 'deepseek': deepseek};
  final active = <String, Map<String, CancellationToken>>{};
  final operations = <String, CancellationToken>{};
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
      if ((request['method'] as String).startsWith('mcp.')) {
        await initialized.asCancellable(cancellation);
        final Object? result;
        switch (request['method']) {
          case 'mcp.status':
            result = mcp.status();
          case 'mcp.catalog':
            result = await mcp.catalog(cancellation);
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
            final updated = await file.exists()
                ? jsonObject(jsonDecode(await file.readAsString()))
                : <String, dynamic>{};
            await mcp.configure(
              jsonObject(updated['mcp_servers'] ?? {}),
              cancellation,
            );
            result = mcp.status();
          default:
            throw StateError('Unknown MCP operation');
        }
        reply?.send({'result': result});
        return;
      }
      if (request['method'] == 'configure') {
        final modelInput = params['model'] as String?;
        final lab =
            params['provider'] as String? ??
            (modelInput?.startsWith('deepseek') == true
                ? 'deepseek'
                : global['default_provider'] as String? ?? 'gpt');
        final provider = providers[lab];
        if (provider == null) throw ArgumentError('Unsupported provider');
        final defaults = jsonObject(providerOptions[lab] ?? {});
        final model =
            modelInput ??
            defaults['model'] as String? ??
            (lab == 'gpt' ? 'gpt-6.1-sol' : deepseek.defaultModel);
        final selected = {
          ...jsonObject(defaults['settings'] ?? {}),
          ...jsonObject(params['settings'] ?? {}),
          if (params['reasoning'] != null) 'reasoning': params['reasoning'],
        };
        final settings = provider.resolveSettings(selected, model: model);
        final info = lab == 'gpt' ? GptModel(model) : null;
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
            'catalog_revision': lab == 'gpt'
                ? gptCatalogRevision
                : deepseek.catalogRevision,
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
      if (!{'respond', 'compact'}.contains(request['method'])) {
        throw StateError('Unknown network operation');
      }
      final lab = requiredString(params, 'provider');
      final provider = providers[lab];
      if (provider == null) throw ArgumentError('Unsupported provider');
      if (id == null) throw ArgumentError('Model request requires a task');
      final input = ModelRequest.fromJson(params);
      void onEvent(Json event) => reply?.send({'event': event});
      final Json result;
      if (request['method'] == 'compact') {
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
