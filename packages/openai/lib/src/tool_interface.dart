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
  const OpenAIToolInterface({this.webSearch = true});
  final bool webSearch;
  @override
  String get id => 'openai';
  @override
  bool get developerContextFirst => true;
  @override
  ConversationItem instructionContext(Json current, Json? previous) => renderInstructions(current, previous);
  @override
  ConversationItem environmentContext(String cwd, {bool replacement = false}) => renderEnvironment(cwd);
  @override
  // CodeModeOnly exposes discovery through exec; web keeps its hosted surface.
  List<ToolDefinition> get definitions => definitionsFor(const []);
  @override
  List<ToolDefinition> definitionsFor(List<Json> deferred) => [
    specs.codeDefinition(deferredTools: deferred.isNotEmpty), if (webSearch) webSearchDefinition,
  ];
  @override
  ToolDefinition get nestedDiscovery => specs.toolSearchDefinition;
  @override
  String? catalogContext(List<Json> current, List<Json>? previous) => renderDeferredNamespaces(current, previous);
  @override
  List<Json> externalCatalog(List<Json> catalog) => [for (final tool in catalog) {
    ...describeTool(tool), 'host_name': tool['name'],
  }];
  @override
  Json search(List<Json> catalog, Json arguments) => discoverTools(catalog, arguments);
  @override
  Map<String, String> get services => {
    if (webSearch) 'web__run': 'web.search',
    for (final tool in historyCatalog) tool['name'] as String: 'history.${(tool['name'] as String).substring(9)}',
    ...mcpResourceMethods,
  };
  @override
  List<Json> get hostCatalog => [
    ...specs.hostCatalog.where((tool) => webSearch || tool['name'] != 'web__run'), ...historyCatalog, ...mcpResourceCatalog,
  ].map(describeTool).toList();
  @override
  List<Json> hostCatalogFor(List<Json> deferred) => [
    ...hostCatalog,
    if (deferred.isNotEmpty) describeTool({...specs.toolSearchDefinition.toJson(), 'format': 'json'}),
  ];
  @override
  ToolRuntime createRuntime(String cwd, CancellationToken cancellation) => _OpenAITools(cwd, cancellation, webSearch);
  @override
  String formatResult(ToolCall call, Json result) => jsonEncode([
    if (call.namespace == 'web' && call.name == 'run' && !result.containsKey('error'))
      {'type': 'input_text', 'text': result['output']}
    else ...[
      {'type': 'input_text', 'text': 'Script ${result.containsKey('error') ? 'failed' : 'completed'}\n'
        'Wall time ${(result['wall_time_seconds'] as num? ?? 0).toStringAsFixed(1)} seconds\nOutput:\n'},
      for (final value in result['output'] as List? ?? []) {'type': 'input_text', 'text': value},
      if (result.containsKey('error')) {'type': 'input_text', 'text': 'Script error:\n${result['error']}'},
    ],
  ]);
  @override
  ConversationItem resultItem(ToolCall call, Json result, {List<Json> images = const []}) {
    final item = super.resultItem(call, result, images: images);
    return ConversationItem(id: item.id, role: item.role, content: [
      for (final part in item.content) {...part, 'native': {'gpt': {'content_items': true}}},
    ]);
  }
}

class _OpenAITools extends ToolRuntime {
  _OpenAITools(String cwd, CancellationToken cancellation, this.webSearch) : host = HostTools(cwd, cancellation);
  final HostTools host;
  final bool webSearch;
  @override
  Future<Object?> call(String name, Object? arguments, {required CancellationToken cancellation, String? cwd}) =>
      host.call(name, arguments, cancellation: cancellation, cwd: cwd);
  @override
  Future<void> close() => host.close();
  @override
  Future<Json> execute(ToolCall call, ToolExecution context) async {
    context.cancellation.throwIfCancelled();
    if (webSearch && call.namespace == 'web' && call.name == 'run') {
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
    final watch = Stopwatch()..start();
    final result = await const CodeMode().execute(
      call.input,
      tool: (name, arguments, {required cancellation}) async {
        cancellation.throwIfCancelled();
        if (!names.containsKey(name)) {
          for (final tool in await context.catalog(cancellation)) {
            names.putIfAbsent(tool['name'] as String, () => tool['host_name'] as String? ?? tool['name'] as String);
          }
        }
        cancellation.throwIfCancelled();
        final hostName = names[name] ?? name;
        final result = await context.call(hostName, arguments, cancellation: cancellation);
        // Codex exposes typed MCP content blocks to JavaScript: the discriminator
        // precedes the payload, even when a server sends its JSON keys sorted.
        // Keep arbitrary payload fields and their values untouched.
        if (hostName.startsWith('mcp__') && result is Map && result['content'] is List) {
          return {...result, 'content': [for (final part in result['content'] as List)
            if (part is Map && part.containsKey('type')) {'type': part['type'], ...part} else part]};
        }
        return result;
      },
      catalog: [for (final name in ordered) {'name': name, 'description': metadata[name]!['description']}],
      values: context.values,
      cancellation: context.cancellation,
    );
    return {...result, 'wall_time_seconds': watch.elapsedMicroseconds / 1000000};
  }
}
