import 'dart:convert';

import 'package:protocol/protocol.dart';

Json _object(Object? value) => value is Map ? jsonObject(value) : const {};

String codeModeName(String name) {
  final result = StringBuffer();
  for (final rune in name.runes) {
    final char = String.fromCharCode(rune);
    result.write(RegExp(result.isEmpty ? r'[A-Za-z_$]' : r'[A-Za-z0-9_$]').hasMatch(char) ? char : '_');
  }
  return result.isEmpty ? '_' : result.toString();
}

Json describeTool(Json tool) {
  final namespaceName = tool['namespace'] as String?;
  final toolName = tool['tool_name'] as String? ?? tool['name'] as String;
  final name = codeModeName(namespaceName == null ? tool['name'] as String
    : namespaceName.isEmpty || namespaceName == 'functions' ? toolName
    : namespaceName.endsWith('_') || toolName.startsWith('_') ? '$namespaceName$toolName'
    : '${namespaceName}__$toolName');
  final freeform = tool['format'] == 'text';
  final input = freeform ? 'string' : schemaType(tool['parameters'] ?? {});
  var output = tool.containsKey('output_schema') ? schemaType(tool['output_schema']) : 'unknown';
  if ((tool['namespace'] as String? ?? '').startsWith('mcp__')) {
    output = output == 'unknown' ? 'CallToolResult' : 'CallToolResult<$output>';
  }
  final supplied = tool['namespace_description'] as String? ?? '';
  final namespace = supplied.trim().isNotEmpty ? supplied.trim()
    : namespaceName != null && !namespaceName.startsWith('mcp__') ? 'Tools in the $namespaceName namespace.' : '';
  final description = '${tool['description'] ?? ''}${namespace.isEmpty ? '' : '\n\n$namespace'}';
  return {...tool, 'name': name, 'description': '$description\n\nexec tool declaration:\n```ts\n'
    'declare const tools: { $name(${freeform ? 'input' : 'args'}: $input): Promise<$output>; };\n```'};
}

// Port of Codex code-mode-protocol/json_schema_types.rs. The work and reference
// budgets are part of the model-visible contract, not just a recursion guard.
String schemaType(Object? schema, {int maxBytes = 16000}) {
  final rendered = _Renderer(schema, maxBytes).render(schema);
  return utf8.encode(rendered).length > maxBytes ? 'unknown' : rendered;
}

class _Renderer {
  _Renderer(this.root, int maxBytes) : remaining = maxBytes * 4;
  final Object? root;
  int remaining, resourceDepth = 0, references = 32;
  bool exhausted = false;
  final active = <String, int>{};
  bool consume(int bytes) {
    if (bytes > remaining) { exhausted = true; return false; }
    remaining -= bytes;
    return true;
  }
  String render(Object? schema) {
    if (exhausted) return 'unknown';
    final nested = !identical(schema, root) && schema is Map && schema.containsKey(r'$id');
    if (nested) resourceDepth++;
    final value = schema == false ? 'never' : schema is Map ? mapType(_object(schema)) : 'unknown';
    if (nested) resourceDepth--;
    return consume(utf8.encode(value).length) ? value : 'unknown';
  }
  String literal(Object? value) {
    if (_literalSize(value) > remaining) { exhausted = true; return 'unknown'; }
    return jsonEncode(_ordered(value));
  }
  String mapType(Json map) {
    if (exhausted) return 'unknown';
    if (map.containsKey(r'$ref')) return reference(map);
    if (map.containsKey('const')) return literal(map['const']);
    if (map['enum'] case final List values) {
      final rendered = <String>[];
      for (final value in values) {
        final item = literal(value);
        if (exhausted || !consume(utf8.encode(item).length)) return 'unknown';
        rendered.add(item);
      }
      if (rendered.isNotEmpty) return rendered.join(' | ');
    }
    for (final key in ['anyOf', 'oneOf', 'allOf']) {
      if (map[key] case final List variants) {
        final rendered = <String>[];
        for (final variant in variants) {
          if (exhausted) return 'unknown';
          final type = render(variant);
          rendered.add(key == 'allOf' && type.contains(' | ') ? '($type)' : type);
        }
        if (rendered.isNotEmpty) return rendered.join(key == 'allOf' ? ' & ' : ' | ');
      }
    }
    if (map['type'] case final List types) {
      final rendered = <String>[];
      for (final type in types.whereType<String>()) {
        if (exhausted) return 'unknown';
        rendered.add(keyword(map, type));
      }
      if (rendered.isNotEmpty) return rendered.join(' | ');
    }
    if (map['type'] case final String type) return keyword(map, type);
    if (['properties', 'additionalProperties', 'required'].any(map.containsKey)) return object(map);
    if (['items', 'prefixItems'].any(map.containsKey)) return array(map);
    return 'unknown';
  }
  String keyword(Json map, String type) => switch (type) {
    'string' || 'boolean' || 'null' => type,
    'number' || 'integer' => 'number',
    'array' => array(map), 'object' => object(map), _ => 'unknown',
  };
  String reference(Json map) {
    var type = 'unknown';
    final ref = map[r'$ref'];
    if (resourceDepth == 0 && ref is String && ref.startsWith('#')) {
      String? pointer;
      try { pointer = Uri.decodeComponent(ref.substring(1)); } on FormatException { /* Unresolvable ref. */ }
      if (pointer != null && (pointer.isEmpty || pointer.startsWith('/'))) {
        final count = active[pointer] ?? 0;
        final target = _pointer(root, pointer);
        if (count < 2 && references > 0 && target != null) {
          references--; active[pointer] = count + 1;
          type = render(target);
          if (count == 0) { active.remove(pointer); } else { active[pointer] = count; }
        }
      }
    }
    if (exhausted) return 'unknown';
    final siblings = {...map}..removeWhere((key, _) => [r'$ref', r'$defs', 'definitions'].contains(key));
    if (!['const', 'enum', 'anyOf', 'oneOf', 'allOf', 'type', 'properties',
      'additionalProperties', 'required', 'items', 'prefixItems'].any(siblings.containsKey)) {
      return type;
    }
    final sibling = mapType(siblings);
    return type == 'unknown' ? sibling : sibling == 'unknown' ? type : '($type) & ($sibling)';
  }
  String array(Json map) {
    if (map.containsKey('items')) {
      final type = render(map['items']);
      return exhausted ? 'unknown' : 'Array<$type>';
    }
    if (map['prefixItems'] case final List items) {
      final types = <String>[];
      for (final item in items) {
        if (exhausted) return 'unknown';
        types.add(render(item));
      }
      if (types.isNotEmpty) return '[${types.join(', ')}]';
    }
    return 'unknown[]';
  }
  String object(Json map) {
    final required = (map['required'] as List? ?? []).whereType<String>().toSet();
    final properties = _object(map['properties']);
    final names = properties.keys.toList()..sort();
    final multiline = properties.values.any((value) => value is Map &&
      value['description'] is String && (value['description'] as String).isNotEmpty);
    final lines = <String>[];
    bool line(String value) { if (!consume(utf8.encode(value).length)) return false; lines.add(value); return true; }
    final pad = multiline ? '  ' : '';
    if (multiline && !line('{')) return 'unknown';
    for (final name in names) {
      if (multiline && properties[name] is Map && properties[name]['description'] is String) {
        for (final description in (properties[name]['description'] as String).split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty)) {
          if (utf8.encode(description).length + 5 > remaining || !line('  // $description')) return 'unknown';
        }
      }
      if (utf8.encode(name).length > remaining) { exhausted = true; return 'unknown'; }
      final property = codeModeName(name) == name ? name : jsonEncode(name);
      final type = render(properties[name]);
      if (exhausted || !line('$pad$property${required.contains(name) ? '' : '?'}: $type;')) return 'unknown';
    }
    if (map.containsKey('additionalProperties')) {
      final additional = map['additionalProperties'];
      if (additional != false) {
        final type = additional == true ? 'unknown' : render(additional);
        if (!line('$pad[key: string]: $type;')) return 'unknown';
      }
    } else if (properties.isEmpty && !line('$pad[key: string]: unknown;')) { return 'unknown'; }
    if (multiline) return line('}') ? lines.join('\n') : 'unknown';
    return lines.isEmpty ? '{}' : '{ ${lines.join(' ')} }';
  }
}

Object? _pointer(Object? root, String pointer) {
  var target = root;
  for (final part in pointer.isEmpty ? <String>[] : pointer.substring(1).split('/')) {
    final key = part.replaceAll('~1', '/').replaceAll('~0', '~');
    if (target is Map && target.containsKey(key)) { target = target[key]; }
    else if (target is List && RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(key) && int.parse(key) < target.length) { target = target[int.parse(key)]; }
    else { return null; }
  }
  return target;
}
Object? _ordered(Object? value) => value is Map ? {for (final key in value.keys.cast<String>().toList()..sort()) key: _ordered(value[key])}
  : value is List ? value.map(_ordered).toList() : value;
int _literalSize(Object? value) => switch (value) {
  null => 4, false => 5, true => 4, num() => value.toString().length,
  String() => utf8.encode(value).length * 6 + 2,
  List() => value.fold(2, (sum, item) => sum + 1 + _literalSize(item)),
  Map() => value.entries.fold(2, (sum, entry) => sum + 4 + utf8.encode(entry.key as String).length * 6 + _literalSize(entry.value)),
  _ => 0,
};
