import 'dart:io';

import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

// Ports from Codex 0ddee3e1d898f7823df97e9aaf08b420be51c804:
// tools/src/tool_search_tests.rs, core/src/tools/context_tests.rs, and
// protocol/src/models.rs. Exercise the final Responses wire representation.
void main() {
  const interface = OpenAIToolInterface(codeModeOnly: false);
  final header = matches(r'^Wall time: \d+\.\d{4} seconds\nOutput:$');
  late CancellationToken cancellation;
  late ToolRuntime runtime;
  setUp(() {
    cancellation = CancellationToken();
    runtime = interface.createRuntime(Directory.current.path, cancellation);
  });
  tearDown(() async { cancellation.cancel(); await runtime.close(); });

  Future<({Json wire, ConversationItem item})> invoke(Json response) async {
    const call = ToolCall(id: 'mcp-call', namespace: 'mcp__archive',
      name: 'probe', input: '{}', format: 'json');
    final result = await runtime.execute(call, ToolExecution(
      call: (_, _, {required cancellation}) async => response,
      catalog: (_) async => [], values: const {}, cancellation: cancellation,
    ));
    final item = interface.resultItem(call, result);
    return (wire: gptInput([item]).single, item: item);
  }

  // top_level_function_search_results_use_the_default_namespace; also
  // exercise the same schema omission inside an MCP namespace.
  for (final namespace in [null, 'mcp__orders']) {
    test('Codex native search omits output schemas for ${namespace ?? 'top-level'} functions', () {
      const parameters = {
        'type': 'object',
        'properties': {'order_id': {'type': 'string'}},
        'required': ['order_id'],
        'additionalProperties': false,
      };
      final catalog = <Json>[{
        'name': namespace == null ? 'lookup_order' : '${namespace}__lookup_order',
        'namespace': ?namespace,
        'tool_name': 'lookup_order', 'description': 'Look up an order',
        'parameters': {
          ...parameters, 'title': 'Order lookup',
          'properties': {
            'order_id': {
              'type': 'string', 'title': 'Order identifier',
              'default': 'unknown', 'examples': ['order-1'],
            },
          },
        },
        'output_schema': {
          'type': 'object',
          'properties': {'result': {'type': 'string'}},
          'required': ['result'],
        },
      }];
      const call = ToolCall(id: 'search-call', name: 'tool_search',
        input: '{"query":"lookup_order"}', format: 'search');
      final result = interface.search(catalog, {'query': 'lookup_order'}, native: true);
      final wire = gptInput([interface.resultItem(call, result)]).single;
      const function = {
        'type': 'function', 'name': 'lookup_order', 'description': 'Look up an order',
        'strict': false, 'defer_loading': true, 'parameters': parameters,
      };
      expect(wire['type'], 'tool_search_output');
      expect(wire['call_id'], 'search-call');
      expect(wire['tools'], [
        if (namespace == null) function
        else {
          'type': 'namespace', 'name': namespace,
          'description': 'Tools in the $namespace namespace.', 'tools': [function],
        },
      ]);
      if (namespace != null) {
        // A new schema revision can leave every indexed word unchanged.
        final nextParameters = {...parameters, 'properties': {'order_id': {'type': 'integer'}}};
        final next = interface.search([
          {...catalog.single, 'parameters': nextParameters},
        ], {'query': 'lookup_order'}, native: true);
        final nextWire = gptInput([interface.resultItem(call, next)]).single;
        expect(nextWire['tools'].single['tools'].single, {...function, 'parameters': nextParameters});
      }
    });
  }

  // preserves_structured_mcp_content and the structured-output timing wrapper.
  for (final isError in [false, true]) {
    test('Codex structured MCP output prefers JSON and preserves isError=$isError', () async {
      final result = await invoke({
        'content': [{'type': 'text', 'text': 'ignored'}],
        'structuredContent': {'result': 'structured'},
        'isError': isError,
      });
      expect(result.wire['type'], 'function_call_output');
      expect(result.wire['call_id'], 'mcp-call');
      expect(result.wire['output'], matches(
        r'^Wall time: \d+\.\d{4} seconds\nOutput:\n\{"result":"structured"\}$'));
      expect(result.item.content.single['is_error'], isError);
    });
  }

  // converts_unstructured_mcp_content_to_items and
  // mcp_tool_output_response_item_includes_wall_time.
  for (final nullStructuredContent in [false, true]) {
    test('Codex unstructured MCP output preserves blocks with ${nullStructuredContent ? 'null' : 'absent'} structured content', () async {
      final result = await invoke({
        'content': [
          {'type': 'text', 'text': 'caption'},
          {'type': 'resource_link', 'uri': 'file:///notes.txt', 'name': 'notes'},
        ],
        if (nullStructuredContent) 'structuredContent': null,
      });
      expect(result.wire['output'], [
        {'type': 'input_text', 'text': header},
        {'type': 'input_text', 'text': 'caption'},
        {'type': 'input_text', 'text': '{"type":"resource_link","uri":"file:///notes.txt","name":"notes"}'},
      ]);
      expect(result.item.content.single['is_error'], false);
    });
  }

  // serializes_image_outputs_as_array, preserves_original_detail_metadata_on_mcp_images,
  // preserves_standard_detail_metadata_on_mcp_images, and
  // mcp_tool_output_response_item_preserves_content_items.
  for (final detail in [null, 'original', 'high']) {
    test('Codex MCP images preserve content order and ${detail ?? 'default'} detail', () async {
      final result = await invoke({
        'content': [
          {'type': 'text', 'text': 'caption'},
          {
            'type': 'image', 'data': 'AQID', 'mimeType': 'image/png',
            if (detail != null) '_meta': {'codex/imageDetail': detail},
          },
        ],
      });
      expect(result.wire['output'], [
        {'type': 'input_text', 'text': header},
        {'type': 'input_text', 'text': 'caption'},
        {'type': 'input_image', 'image_url': 'data:image/png;base64,AQID', 'detail': detail ?? 'high'},
      ]);
    });
  }
}
