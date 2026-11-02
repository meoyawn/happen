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
    this.standaloneWebSearch = false, this.sleepTool = true, this.goals = true, this.codeModeOnly = true});
  final bool webSearch, imageGeneration, standaloneWebSearch, sleepTool, goals, codeModeOnly;
  @override
  String get id => 'openai';
  @override
  bool get developerContextFirst => true;
  @override
  bool isCodeCall(ToolCall call) => (call.namespace == null || call.namespace == 'functions') && {'exec', 'wait'}.contains(call.name);
  @override
  ConversationItem instructionContext(Json current, Json? previous) => renderInstructions(current, previous);
  @override
  ConversationItem environmentContext(String cwd, {bool replacement = false}) => renderEnvironment(cwd);
  @override
  List<ToolDefinition> get definitions => definitionsFor(const []);
  @override
  List<ToolDefinition> definitionsFor(List<Json> deferred) => [
    specs.codeDefinition(deferredTools: deferred.isNotEmpty, imageGeneration: imageGeneration, goals: goals, codeModeOnly: codeModeOnly), specs.waitDefinition,
    if (!codeModeOnly) ...[
      for (final name in ['exec_command', 'write_stdin']) specs.directDefinition(specs.hostCatalog.singleWhere((tool) => tool['name'] == name)),
      if (deferred.isNotEmpty) ...mcpResourceCatalog.map(specs.directDefinition),
      specs.directDefinition(specs.hostCatalog.singleWhere((tool) => tool['name'] == 'curr_time')),
    ],
    if (sleepTool) specs.sleepDefinition,
    if (!codeModeOnly) ...[
      for (final name in ['apply_patch', 'view_image']) specs.directDefinition(specs.hostCatalog.singleWhere((tool) => tool['name'] == name)),
      if (imageGeneration) specs.directDefinition(imageGenerationCatalog),
      if (goals) ...goalCatalog.map(specs.directDefinition),
      if (deferred.isNotEmpty) specs.directSearchDefinition,
    ],
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
  Json search(List<Json> catalog, Json arguments, {bool native = false}) => discoverTools(catalog, arguments, native: native);
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
    ...hostCatalog.where((tool) => codeModeOnly || deferred.isNotEmpty || !mcpResourceMethods.containsKey(tool['name'])),
    if (deferred.isNotEmpty) describeTool(specs.toolSearchCatalog),
  ];
  @override
  ToolRuntime createRuntime(String cwd, CancellationToken cancellation) => _OpenAITools(cwd, cancellation, webSearch && standaloneWebSearch, sleepTool, codeModeOnly);
  @override
  String formatResult(ToolCall call, Json result) {
    if (call.format == 'search') return jsonEncode(result['tools'] ?? []);
    return jsonEncode([
    if (result['notification'] case final String notice) {'type': 'input_text', 'text': notice}
    else if (call.namespace == 'clock' && call.name == 'sleep')
      {'type': 'input_text', 'text': result['output'] ?? result['error']}
    else if (call.namespace == 'web' && call.name == 'run' && !result.containsKey('error'))
      {'type': 'input_text', 'text': result['output']}
    else if (!codeModeOnly && !((call.namespace == null || call.namespace == 'functions') && {'exec', 'wait'}.contains(call.name))) ...[
      if (result['content'] is List) ...(result['content'] as List).map(jsonObject)
      else {'type': 'input_text', 'text': result['output'] ?? result['error'] ?? ''},
    ]
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
  }
  @override
  ConversationItem resultItem(ToolCall call, Json result, {List<Json> images = const []}) {
    if (call.format == 'search') return super.resultItem(call, result);
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
  _OpenAITools(String cwd, CancellationToken cancellation, this.webSearch, this.sleepTool, this.codeModeOnly)
    : host = HostTools(cwd, cancellation), cells = CodeSession(cancellation);
  final HostTools host;
  final CodeSession cells;
  @override
  bool get hasRunningCells => cells.hasRunningCells;
  final bool webSearch, sleepTool, codeModeOnly;
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
      if (!codeModeOnly) return _direct(call, context);
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
        // The patch's native prose is not its nested Code Mode return value.
        if (hostName == 'apply_patch') return <String, dynamic>{};
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

  Future<Json> _direct(ToolCall call, ToolExecution context) async {
    final arguments = call.format == 'text' ? call.input : jsonDecode(call.input);
    if (call.format == 'search' && call.name == 'tool_search') {
      return jsonObject(await context.call('tool_search', arguments, cancellation: context.cancellation));
    }
    final String name;
    final builtin = specs.hostCatalog.where((tool) =>
      (tool['namespace'] ?? 'functions') == (call.namespace ?? 'functions') &&
      (tool['tool_name'] ?? tool['name']) == call.name && (webSearch || tool['name'] != 'web__run')).firstOrNull;
    if (builtin != null) {
      name = builtin['namespace'] == null ? builtin['name'] as String : '${builtin['namespace']}__${call.name}';
    } else if (call.namespace?.startsWith('mcp__') == true) {
      // Native MCP names are already canonical. The live MCP owner validates
      // availability; rendering a JavaScript catalog here adds an unused hop.
      name = '${call.namespace}__${call.name}';
    } else {
      final catalog = await context.catalog(context.cancellation);
      final tool = catalog.where((tool) => (tool['namespace'] ?? 'functions') == (call.namespace ?? 'functions') &&
        (tool['tool_name'] ?? tool['name']) == call.name).firstOrNull;
      if (tool == null) throw StateError('Unknown OpenAI tool: ${call.namespace}.${call.name}');
      name = tool['host_name'] as String? ?? tool['name'] as String;
    }
    final watch = Stopwatch()..start();
    final value = await context.call(name, arguments, cancellation: context.cancellation);
    if (name == 'apply_patch') {
      final paths = <({String kind, String path})>[];
      for (final match in RegExp(r'^\*\*\* (Add File|Update File|Delete File|Move to): (.+)$', multiLine: true).allMatches(call.input)) {
        if (match[1] == 'Move to') { paths[paths.length - 1] = (kind: 'M', path: match[2]!); }
        else { paths.add((kind: switch (match[1]) {'Add File' => 'A', 'Delete File' => 'D', _ => 'M'}, path: match[2]!)); }
      }
      return {'output': 'Exit code: 0\nWall time: ${(watch.elapsedMicroseconds / 1000000).toStringAsFixed(1)} seconds\nOutput:\n'
        'Success. Updated the following files:\n${[
          for (final kind in ['A', 'M', 'D']) for (final path in paths.where((path) => path.kind == kind)) '$kind ${path.path}',
        ].join('\n')}\n'};
    }
    if (name == 'exec_command' || name == 'write_stdin') {
      final result = jsonObject(value);
      return {'output': [
        if (result['chunk_id'] != null) 'Chunk ID: ${result['chunk_id']}',
        'Wall time: ${(result['wall_time_seconds'] as num).toStringAsFixed(4)} seconds',
        if (result['exit_code'] != null) 'Process exited with code ${result['exit_code']}',
        if (result['session_id'] != null) 'Process running with session ID ${result['session_id']}',
        if (result['original_token_count'] != null) 'Original token count: ${result['original_token_count']}',
        'Output:', result['output'],
      ].join('\n')};
    }
    if (name == 'view_image' || name == 'image_gen__imagegen') {
      final result = jsonObject(value);
      return {'content': [
        {'type': 'input_image', 'image_url': result['image_url'], 'detail': result['detail'] ?? 'high'},
        if (result['output_hint'] case final String hint) {'type': 'input_text', 'text': hint},
      ]};
    }
    if (name.startsWith('mcp__')) {
      final result = jsonObject(value);
      final header = 'Wall time: ${(watch.elapsedMicroseconds / 1000000).toStringAsFixed(4)} seconds\nOutput:';
      if (result['structuredContent'] != null) {
        return {'output': '$header\n${jsonEncode(result['structuredContent'])}', if (result['isError'] == true) 'error': 'MCP tool failed'};
      }
      return {'content': [
        {'type': 'input_text', 'text': header},
        for (final part in (result['content'] as List? ?? []).map(jsonObject))
          if (part['type'] == 'text') {'type': 'input_text', 'text': part['text']}
          else if (part['type'] == 'image') {'type': 'input_image',
            'image_url': 'data:${part['mimeType']};base64,${part['data']}', 'detail': part['_meta']?['codex/imageDetail'] ?? 'high'}
          else {'type': 'input_text', 'text': part['type'] == 'audio'
            ? 'audio content omitted because you do not support audio input' : jsonEncode(part)},
      ], if (result['isError'] == true) 'error': 'MCP tool failed'};
    }
    return {'output': value is String ? value : jsonEncode(value)};
  }
}
