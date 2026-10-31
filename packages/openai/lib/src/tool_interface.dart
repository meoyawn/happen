import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:code_mode/code_mode.dart';
import 'package:protocol/protocol.dart';

import 'history_tools.dart';
import 'declarations.dart';
import 'instructions.dart';
import 'discovery.dart';
import 'tool_catalog.dart';
import 'tool_specs.dart' as specs;
import 'tools.dart';
import 'web_search.dart';

class OpenAIToolInterface extends ToolInterface {
  const OpenAIToolInterface();
  @override
  String get id => 'openai';
  @override
  ConversationItem instructionContext(Json current, Json? previous) => renderInstructions(current, previous);
  @override
  ConversationItem environmentContext(String cwd, {bool replacement = false}) => renderEnvironment(cwd);
  @override
  List<ToolDefinition> get definitions => [specs.codeDefinition, webSearchDefinition, specs.toolSearchDefinition];
  @override
  ToolDefinition get discovery => specs.toolSearchDefinition;
  @override
  String? catalogContext(List<Json> current, List<Json>? previous) => renderDeferredNamespaces(current, previous);
  @override
  List<Json> externalCatalog(List<Json> catalog) => [for (final tool in catalog) {
    ...describeTool(tool), 'host_name': tool['name'],
  }];
  @override
  ToolDiscovery search(List<Json> catalog, Json arguments, {bool nested = false}) =>
      discoverTools(catalog, arguments, nested: nested);
  @override
  Map<String, String> get services => {
    'web__run': 'web.search',
    for (final tool in historyCatalog) tool['name'] as String: 'history.${(tool['name'] as String).substring(9)}',
    ...mcpResourceMethods,
  };
  @override
  List<Json> get hostCatalog => [
    ...specs.hostCatalog, ...historyCatalog, ...mcpResourceCatalog,
    {...specs.toolSearchDefinition.toJson(), 'format': 'json'},
  ].map(describeTool).toList();
  @override
  ToolRuntime createRuntime(String cwd, CancellationToken cancellation) => _OpenAITools(cwd, cancellation);
  @override
  String formatResult(ToolCall call, Json result) =>
      call.namespace == 'web' && call.name == 'run' && !result.containsKey('error')
          ? result['output'] as String
          : jsonEncode(result.containsKey('error') ? result : {'output': result['output']});
}

class _OpenAITools extends ToolRuntime {
  _OpenAITools(String cwd, CancellationToken cancellation) : host = HostTools(cwd, cancellation);
  final HostTools host;
  @override
  Future<Object?> call(String name, Object? arguments, {required CancellationToken cancellation, String? cwd}) =>
      host.call(name, arguments, cancellation: cancellation, cwd: cwd);
  @override
  Future<void> close() => host.close();
  @override
  Future<Json> execute(ToolCall call, ToolExecution context) async {
    context.cancellation.throwIfCancelled();
    if (call.namespace == 'web' && call.name == 'run') {
      return {'output': await context.call('web__run', webSearchCommands(jsonDecode(call.input)), cancellation: context.cancellation)};
    }
    if (call.name != 'exec' || call.namespace != null && call.namespace != 'functions') {
      throw StateError('Unknown OpenAI tool: ${call.namespace}.${call.name}');
    }
    final catalog = await context.catalog(context.cancellation);
    final names = <String, String>{};
    for (final tool in catalog) {
      names.putIfAbsent(tool['name'] as String, () => tool['host_name'] as String? ?? tool['name'] as String);
    }
    final metadata = <String, Json>{};
    for (final tool in catalog) { metadata.putIfAbsent(tool['name'] as String, () => tool); }
    final ordered = metadata.keys.toList()..sort();
    return const CodeMode().execute(
      call.input,
      tool: (name, arguments, {required cancellation}) async {
        cancellation.throwIfCancelled();
        if (!names.containsKey(name)) {
          for (final tool in await context.catalog(cancellation)) {
            names.putIfAbsent(tool['name'] as String, () => tool['host_name'] as String? ?? tool['name'] as String);
          }
        }
        cancellation.throwIfCancelled();
        return context.call(names[name] ?? name, arguments, cancellation: cancellation);
      },
      catalog: [for (final name in ordered) {'name': name, 'description': metadata[name]!['description']}],
      values: context.values,
      cancellation: context.cancellation,
    );
  }
}
