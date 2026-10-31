import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:code_mode/code_mode.dart';
import 'package:protocol/protocol.dart';

import 'discovery.dart';

Future<Json> executeCode(String code, ToolExecution context) async {
  context.cancellation.throwIfCancelled();
  final catalog = await context.catalog(context.cancellation);
  final calls = <Json>[];
  final images = <Json>[];
  final result = await const CodeMode().execute(
    'const __source = ${jsonEncode(code)};\nconst __catalog = ${jsonEncode(catalog)};\n$_runtime',
    catalog: const [],
    cancellation: context.cancellation,
    awaitPending: false,
    tool: (name, input, {required cancellation}) async {
      cancellation.throwIfCancelled();
      final row = <String, dynamic>{'tool': name == '__fetch' ? 'fetch' : name == '__search' ? 'search' : name, 'status': 'running', 'input': input};
      try {
        if (name == '__search') {
          final output = searchCodeArguments(catalog, (jsonObject(input)['args'] as List).cast<Object?>());
          calls.add(row);
          row['status'] = 'completed';
          return output;
        }
        calls.add(row);
        final tool = name == '__fetch' ? null : catalog.where((tool) => tool['name'] == name).firstOrNull;
        if (name != '__fetch' && tool == null) throw StateError('Unknown Code Mode tool: $name');
        final output = await context.call(name == '__fetch' ? '__fetch' : tool!['host_name'] as String? ?? name, input,
          cancellation: cancellation);
        row['status'] = 'completed';
        if (output is Map && output['isError'] == true) {
          final message = (output['content'] as List? ?? []).where((part) => part['type'] == 'text').map((part) => part['text']).join('\n').trim();
          throw StateError(message.isEmpty ? 'MCP tool returned an error' : message);
        }
        if (output is Map && output['content'] is List) {
          images.addAll((output['content'] as List).map(jsonObject)
            .where((part) => part['type'] == 'image').map(toolImage));
        }
        if (tool?['transport'] == 'mcp') {
          if (output is Map && output.containsKey('structuredContent')) return output['structuredContent'];
          if (output is Map && output['content'] is List) {
            final text = (output['content'] as List).where((part) => part['type'] == 'text').map((part) => part['text']).join('\n');
            if (tool?['output_schema'] == null && (text.startsWith('{') || text.startsWith('['))) {
              try { return jsonDecode(text); } on FormatException { /* Return ordinary text. */ }
            }
            return text.isEmpty ? null : text;
          }
        }
        return output;
      } catch (_) {
        row['status'] = 'error';
        rethrow;
      }
    },
  );
  context.cancellation.cancel();
  return {'output': (result['output'] as List).join('\n'), 'toolCalls': calls, 'files': <Json>[],
    if (images.isNotEmpty) 'images': images,
    if (jsonObject(result['values'])['__opencode_error'] == true) 'error': true};
}

const _runtime = r'''
const __host = tools;
const __logs = [];
const __console = {log: (...args) => __logs.push(args.map(value => typeof value === "string" ? value : JSON.stringify(value)).join(" "))};
const __search = (...args) => __host.__search({args});
function __node(path = "") {
  return new Proxy(() => {}, {
    get(_, name) {
      if (name === "then") return undefined;
      if (path === "" && name === "search" && !__catalog.some(tool => tool.name === "search" || tool.name.startsWith("search."))) return __search;
      return __node(path ? path + "." + String(name) : String(name));
    },
    apply(_, __, args) {
      if (args.length > 1) throw new Error("Tools expect at most one input object");
      if (!__catalog.some(tool => tool.name === path)) throw new Error("Unknown tool '" + path + "'. Use search to find available tools.");
      return __host[path](args[0] ?? {});
    },
    ownKeys() { return [...new Set(__catalog.map(tool => tool.name).filter(name => name.startsWith(path ? path + "." : "")).map(name => name.slice(path ? path.length + 1 : 0).split(".")[0]))]; },
    getOwnPropertyDescriptor() { return {configurable: true, enumerable: true}; }
  });
}
const __fetch = async (url, options = {}) => {
  const raw = await __host.__fetch({url: String(url), ...options});
  const response = typeof raw === "string" ? JSON.parse(raw) : raw;
  return {...response, ok: response.status >= 200 && response.status < 300,
    text: async () => response.body, json: async () => JSON.parse(response.body),
    headers: {get: name => response.headers[String(name).toLowerCase()] ?? null}};
};
const __AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
let __program;
// Compile candidates without executing them. The first valid suffix is the final
// top-level expression; declarations/control statements retain normal semantics.
for (const offset of [0, ...Array.from(__source.matchAll(/[;\n}]/g), match => match.index + 1)]) {
  const suffix = __source.slice(offset).trim().replace(/;\s*$/, "");
  if (!suffix) continue;
  try { __program = new __AsyncFunction("tools", "search", "fetch", "console", __source.slice(0, offset) + "\nreturn (\n" + suffix + "\n);"); break; } catch (_) {}
}
__program ??= new __AsyncFunction("tools", "search", "fetch", "console", __source);
try {
  const value = await __program(__node(), __search, __fetch, __console);
  const output = typeof value === "string" ? value : JSON.stringify(value ?? null, null, 2);
  return [output, __logs.length ? "Logs:\n" + __logs.join("\n") : undefined].filter(value => value !== undefined && value !== "").join("\n\n");
} catch (error) {
  store("__opencode_error", true);
  return [String(error), __logs.length ? "Logs:\n" + __logs.join("\n") : undefined].filter(Boolean).join("\n\n");
}
''';
