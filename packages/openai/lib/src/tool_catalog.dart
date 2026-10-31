import 'dart:convert';

import 'package:protocol/protocol.dart';

// Codex ToolsState and tools_budget.rs: reserve names first, then share the
// remaining UTF-8 budget across description characters in round-robin order.
String? renderDeferredNamespaces(List<Json> catalog, List<Json>? previous) {
  Map<String, String> namespaces(List<Json> tools) {
    final descriptions = <String, String>{};
    for (final tool in tools) {
      final name = tool['namespace'] as String;
      if (name == 'functions') continue;
      final description = tool['namespace_description'] as String?;
      if (descriptions[name]?.trim().isNotEmpty == true) continue;
      descriptions[name] = description?.trim().isNotEmpty == true ? description! : 'Tools in the $name namespace.';
    }
    return {for (final name in descriptions.keys.toList()..sort()) name: _description(descriptions[name]!)};
  }
  final current = namespaces(catalog), before = previous == null ? null : namespaces(previous);
  if (before == null && current.isEmpty || before != null && current.length == before.length &&
    current.entries.every((entry) => before[entry.key] == entry.value)) {
    return null;
  }
  final groups = <({String label, Map<String, String> rows})>[
    if (before == null) (label: 'Deferred tool namespaces', rows: current) else ...[
      (label: 'Added deferred tool namespaces', rows: {for (final entry in current.entries) if (before[entry.key] != entry.value) entry.key: entry.value}),
      (label: 'Removed deferred tool namespaces', rows: {for (final entry in before.entries) if (!current.containsKey(entry.key)) entry.key: entry.value}),
    ],
  ];
  final empty = current.isEmpty ? 'No deferred tool namespaces remain.\n' : '';
  final fixed = 1 + groups.where((group) => group.rows.isNotEmpty).fold<int>(0,
    (sum, group) => sum + _bytes('${group.label}:\n')) + _bytes(empty);
  final budget = (4096 - _bytes('<tools></tools>') - fixed).clamp(0, 4096);
  final entries = groups.expand((group) => group.rows.entries).toList();
  final names = entries.fold<int>(0, (sum, entry) => sum + _bytes('- ${entry.key}\n'));
  final retained = List<int?>.filled(entries.length, 0);
  if (names > budget) {
    var remaining = (budget - groups.where((group) => group.rows.isNotEmpty).length * 64).clamp(0, budget);
    for (var index = 0; index < entries.length; index++) {
      final size = _bytes('- ${entries[index].key}\n');
      if (size <= remaining) { remaining -= size; } else { retained[index] = null; }
    }
  } else {
    var remaining = budget - names;
    final needed = entries.fold<int>(0, (sum, entry) => sum + (entry.value.isEmpty ? 0 : 2 + _bytes(entry.value)));
    if (needed <= remaining) {
      for (var index = 0; index < entries.length; index++) { retained[index] = _bytes(entries[index].value); }
    } else {
      final characters = entries.map((entry) => entry.value.runes.iterator).toList();
      final active = [for (var index = 0; index < entries.length; index++) if (entries[index].value.isNotEmpty) index];
      while (active.isNotEmpty) {
        final index = active.removeAt(0), iterator = characters[index];
        if (!iterator.moveNext()) continue;
        final size = _bytes(String.fromCharCode(iterator.current)), first = retained[index] == 0;
        if (size + (first ? 2 : 0) <= remaining) {
          remaining -= size + (first ? 2 : 0);
          retained[index] = retained[index]! + size;
          active.add(index);
        }
      }
    }
  }
  final body = StringBuffer('<tools>\n');
  var index = 0;
  for (final group in groups) {
    if (group.rows.isEmpty) continue;
    body.writeln('${group.label}:');
    var omitted = 0;
    for (final entry in group.rows.entries) {
      final count = retained[index++];
      if (count == null) { omitted++; continue; }
      final suffix = count == 0 ? '' : count == _bytes(entry.value) ? ': ${entry.value}'
        : count < 3 ? '' : ': ${_prefix(entry.value, count - 3)}...';
      body.writeln('- ${entry.key}$suffix');
    }
    if (omitted > 0) body.writeln('... $omitted additional namespaces omitted.');
  }
  body.write('$empty</tools>');
  return body.toString();
}

int _bytes(String text) => utf8.encode(text).length;
String _prefix(String text, int bytes) {
  final result = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune), size = _bytes(String.fromCharCode(rune));
    if (size > bytes) break;
    result.write(char); bytes -= size;
  }
  return result.toString();
}
String _description(String text) {
  final runes = text.split('\n').first.trim().runes.toList();
  return String.fromCharCodes(runes.length > 250 ? runes.take(247) : runes) + (runes.length > 250 ? '...' : '');
}
