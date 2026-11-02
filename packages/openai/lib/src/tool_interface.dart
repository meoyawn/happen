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
import 'image_generation.dart';
import 'goals.dart';

class OpenAIToolInterface extends ToolInterface {
  const OpenAIToolInterface({this.webSearch = true, this.imageGeneration = false,
    this.standaloneWebSearch = false, this.sleepTool = true, this.goals = true});
  final bool webSearch, imageGeneration, standaloneWebSearch, sleepTool, goals;
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
    specs.codeDefinition(deferredTools: deferred.isNotEmpty, imageGeneration: imageGeneration, goals: goals), specs.waitDefinition,
    if (sleepTool) specs.sleepDefinition,
    if (webSearch) standaloneWebSearch ? webSearchDefinition : hostedWebSearchDefinition,
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
    if (webSearch && standaloneWebSearch) 'web__run': 'web.search',
    if (imageGeneration) 'image_gen__imagegen': 'image.generate',
    if (goals) for (final tool in goalCatalog) tool['name'] as String: 'goal.${tool['name']}',
    for (final tool in historyCatalog) tool['name'] as String: 'history.${(tool['name'] as String).substring(9)}',
    ...mcpResourceMethods,
  };
  @override
  List<Json> get hostCatalog => [
    ...specs.hostCatalog.where((tool) => webSearch && standaloneWebSearch || tool['name'] != 'web__run'), ...historyCatalog, ...mcpResourceCatalog,
    if (imageGeneration) imageGenerationCatalog,
    if (goals) ...goalCatalog,
  ].map((tool) => describeTool(tool, namespaceInstructions: false)).toList();
  @override
  List<Json> hostCatalogFor(List<Json> deferred) => [
    ...hostCatalog,
    if (deferred.isNotEmpty) describeTool(specs.toolSearchCatalog),
  ];
  @override
  ToolRuntime createRuntime(String cwd, CancellationToken cancellation) => _OpenAITools(cwd, cancellation, webSearch && standaloneWebSearch, sleepTool);
  @override
  String formatResult(ToolCall call, Json result) => jsonEncode([
    if (result['notification'] case final String notice) {'type': 'input_text', 'text': notice}
    else if (call.namespace == 'clock' && call.name == 'sleep')
      {'type': 'input_text', 'text': result['output'] ?? result['error']}
    else if (call.namespace == 'web' && call.name == 'run' && !result.containsKey('error'))
      {'type': 'input_text', 'text': result['output']}
    else ...[
      {'type': 'input_text', 'text': '${result['cell_id'] != null ? 'Script running with cell ID ${result['cell_id']}'
          : result['terminated'] == true ? 'Script terminated' : 'Script ${result.containsKey('error') ? 'failed' : 'completed'}'}\n'
        'Wall time ${(result['wall_time_seconds'] as num? ?? 0).toStringAsFixed(1)} seconds\nOutput:\n'},
      if (result['content'] is List) ...(result['content'] as List).map(jsonObject)
      else ...[
        for (final value in result['output'] as List? ?? []) {'type': 'input_text', 'text': value},
        if (result.containsKey('error')) {'type': 'input_text', 'text': 'Script error:\n${result['error']}'},
      ],
    ],
  ]);
  @override
  ConversationItem resultItem(ToolCall call, Json result, {List<Json> images = const []}) {
    if (result['notification'] case final String notice) {
      final item = ConversationItem.toolResult(call, notice);
      return ConversationItem(id: item.id, role: item.role, native: {'gpt': {'notification': true}}, content: [
        for (final part in item.content) {...part, 'native': {'gpt': {'name': 'exec'}}},
      ]);
    }
    final shadow = <Json>[];
    for (final part in (result['content'] as List? ?? []).map(jsonObject).where((part) => part['type'] == 'input_image')) {
      try { shadow.add(toolImage(part)); }
      on FormatException { /* Preserve the upstream inline value even if no local preview is possible. */ }
    }
    final item = super.resultItem(call, result, images: [...images, ...shadow]);
    final tokens = result['text_audio_tokens'] as int?;
    return ConversationItem(id: item.id, role: item.role, content: [
      for (final part in item.content) {
        ...part,
        if (tokens != null) 'output_token_estimate': tokens +
          (utf8.encode(jsonObject((jsonDecode(part['output'] as String) as List).first)['text'] as String).length + 3) ~/ 4,
        'native': {'gpt': {'content_items': true, if (shadow.isNotEmpty) 'inline_images': true}},
      },
    ]);
  }
}

class _OpenAITools extends ToolRuntime {
  _OpenAITools(String cwd, CancellationToken cancellation, this.webSearch, this.sleepTool)
    : host = HostTools(cwd, cancellation), cells = CodeSession(cancellation);
  final HostTools host;
  final CodeSession cells;
  @override
  bool get hasRunningCells => cells.hasRunningCells;
  final bool webSearch, sleepTool;
  @override
  Future<Object?> call(String name, Object? arguments, {required CancellationToken cancellation, String? cwd}) =>
      host.call(name, arguments, cancellation: cancellation, cwd: cwd);
  @override
  Future<void> close() async { await cells.close(); await host.close(); }
  @override
  Future<Json> execute(ToolCall call, ToolExecution context) async {
    context.cancellation.throwIfCancelled();
    if (sleepTool && call.namespace == 'clock' && call.name == 'sleep') {
      final arguments = jsonObject(jsonDecode(call.input));
      final duration = arguments['duration_ms'];
      if (arguments.keys.any((key) => key != 'duration_ms') || duration is! int || duration < 1 || duration > 43200000) {
        return {'error': 'duration_ms must be between 1 and 43200000'};
      }
      final watch = Stopwatch()..start();
      await cancellableDelay(Duration(milliseconds: duration), context.cancellation);
      return {'output': 'Wall time: ${(watch.elapsedMicroseconds / 1000000).toStringAsFixed(4)} seconds\nSleep completed.'};
    }
    if (webSearch && call.namespace == 'web' && call.name == 'run') {
      return {'output': await context.call('web__run', webSearchCommands(jsonDecode(call.input)), cancellation: context.cancellation)};
    }
    if (call.name == 'wait' && (call.namespace == null || call.namespace == 'functions')) {
      return cells.wait(jsonObject(jsonDecode(call.input)), cancellation: context.cancellation);
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
    return cells.execute(
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
      notify: (text) async { await context.notify?.call({'notification': text}); },
    );
  }
}
