import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'code_mode.dart';
import 'native_tools.dart';
import 'tool_specs.dart';
import 'tool_catalog.dart';
import 'instructions.dart';
import 'mcp_instructions.dart';
import 'skills.dart';
import 'images.dart';

class OpenCodeToolInterface extends ToolInterface {
  const OpenCodeToolInterface();
  @override
  String get id => 'opencode';
  @override
  String baseInstructions(String model, String supplied) => openCodeInstructions;
  @override
  ConversationItem instructionContext(Json current, Json? previous) => renderInstructions(current, previous);
  @override
  ConversationItem environmentContext(String cwd, {bool replacement = false}) => renderEnvironment(cwd, replacement: replacement);
  @override
  List<ToolDefinition> get definitions => openCodeDefinitions;
  @override
  String? catalogContext(List<Json> current, List<Json>? previous) {
    final catalog = summarizeToolCatalog([...hostCatalog, ...externalCatalog(current)]);
    final before = previous == null ? null : summarizeToolCatalog([...hostCatalog, ...externalCatalog(previous)]);
    final parts = [
      if (before == null) renderToolCatalog(catalog)
      else if (jsonEncode(before) != jsonEncode(catalog)) updateToolCatalog(before, catalog),
      if (renderMcpInstructions(current, previous) case final String text) text,
    ];
    return parts.isEmpty ? null : parts.join('\n\n');
  }
  @override
  Map<String, String> get services => const {
    'skill': 'skills.read',
    'websearch': 'web.search', 'webfetch': 'web.search', '__fetch': 'web.search',
    '__resource_list': 'resources/list', '__resource_templates': 'resources/templates/list',
    'opencode.read_mcp_resource': 'resources/read',
  };
  @override
  List<Json> get hostCatalog => const [
    {'name': 'opencode.list_mcp_resources', 'nested': true, 'description': 'List documents, records, and other data exposed by MCP servers. Use this when the user refers to something that is not a local file, such as a URI with a custom scheme, then load a match with read_mcp_resource. Each entry names the server to read it from. Templates are resources addressed by a parameter such as a record ID; fill in the uriTemplate placeholders before reading.',
      'parameters': {'type': 'object', 'properties': {'server': {'type': 'string', 'description': 'MCP server name as configured. Omit to list every server.'}}, 'additionalProperties': false}},
    {'name': 'opencode.read_mcp_resource', 'nested': true, 'description': 'Read a discovered MCP resource.',
      'parameters': {'type': 'object', 'properties': {
        'server': {'type': 'string', 'description': 'The server field of the discovered resource.'},
        'uri': {'type': 'string', 'description': 'Exact resource URI from discovery, an expanded uriTemplate, or the user.'},
      }, 'required': ['server', 'uri'], 'additionalProperties': false}},
  ];
  @override
  List<Json> externalCatalog(List<Json> catalog) => [for (final tool in catalog) {
    ...tool,
    'name': (tool['namespace'] as String).startsWith('mcp__')
      ? '${mcpNamespace(tool['server_name'] as String? ?? (tool['namespace'] as String).substring(5))}.${mcpNamespace(tool['original_name'] as String? ?? tool['tool_name'] as String)}'
      : '${tool['namespace']}.${tool['tool_name']}',
    'host_name': tool['name'],
    'nested': true,
    'transport': (tool['namespace'] as String).startsWith('mcp__') ? 'mcp' : 'client',
  }..removeWhere((key, _) => key == 'namespace_description' && (tool['namespace'] as String).startsWith('mcp__'))];
  @override
  ToolRuntime createRuntime(String cwd, CancellationToken cancellation) => _OpenCodeTools(cwd, cancellation);
  @override
  Future<List<Json>> prepareImages(List<Json> images, {required CancellationToken cancellation}) =>
      prepareOpenCodeImages(images, cancellation: cancellation);
  @override
  String formatResult(ToolCall call, Json result) {
    final value = result.containsKey('error') && result['error'] != true ? result['error'] : result['output'];
    if (value is String) return value;
    if (value is Map && value['content'] is List) {
      return (value['content'] as List).where((part) => part['type'] == 'text').map((part) => part['text']).join('\n');
    }
    return const JsonEncoder.withIndent('  ').convert(value);
  }
}

class _OpenCodeTools extends ToolRuntime {
  _OpenCodeTools(String cwd, CancellationToken cancellation) : native = NativeTools(cwd, cancellation);
  final NativeTools native;
  @override
  Future<Object?> call(String name, Object? arguments, {required CancellationToken cancellation, String? cwd}) =>
      native.execute(name, jsonObject(arguments), cancellation: cancellation, cwd: cwd);
  @override
  Future<void> close() => native.close();
  @override
  Future<List<String>> notifications({bool wait = false, required CancellationToken cancellation}) =>
      native.notifications(wait: wait, cancellation: cancellation);
  @override
  Future<Json> execute(ToolCall call, ToolExecution context) async {
    context.cancellation.throwIfCancelled();
    if (call.namespace != null) throw StateError('Unknown OpenCode tool namespace: ${call.namespace}');
    final definition = openCodeDefinitions.where((tool) => tool.name == call.name).firstOrNull;
    if (definition == null) throw StateError('Unknown OpenCode tool: ${call.name}');
    final input = jsonObject(jsonDecode(call.input));
    validateToolInput(input, definition.parameters, call.name);
    if (call.name == 'execute') {
      return executeCode(input['code'] as String, ToolExecution(
        catalog: context.catalog, values: const {}, cancellation: context.cancellation,
        call: (name, arguments, {required cancellation}) async {
          if (name == 'opencode.list_mcp_resources') {
            final pages = await Future.wait([
              context.call('__resource_list', arguments, cancellation: cancellation),
              context.call('__resource_templates', arguments, cancellation: cancellation),
            ]);
            return {'resources': jsonObject(pages[0])['resources'] ?? [],
              'templates': jsonObject(pages[1])['resourceTemplates'] ?? []};
          }
          return context.call(name, name == '__fetch' ? {'fetch': arguments} : arguments, cancellation: cancellation);
        },
      ));
    }
    if (call.name == 'skill') {
      final skill = jsonObject(await context.call('skill', input, cancellation: context.cancellation));
      return {'output': skillOutput(skill)};
    }
    if (call.name == 'websearch' || call.name == 'webfetch') {
      return {'output': await context.call(call.name, input, cancellation: context.cancellation)};
    }
    return jsonObject(await context.call(call.name, input, cancellation: context.cancellation));
  }
}
