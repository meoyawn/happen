import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

/// Codex's metadata budget: two percent of context, or 8,000 characters when
/// unknown. Explicit overrides are capped at 10,000 approximate tokens.
class SkillBudget {
  SkillBudget({int? contextWindow, int? maxTokens})
    : tokens = maxTokens != null || contextWindow != null && contextWindow > 0,
      limit = maxTokens != null ? maxTokens.clamp(1, 10000)
        : contextWindow != null && contextWindow > 0 ? (contextWindow * 2 ~/ 100).clamp(1, 1 << 30) : 8000;
  final bool tokens;
  final int limit;
  int cost(String text) => tokens ? (utf8.encode(text).length + 3) ~/ 4 : text.runes.length;
}

class SkillContextUpdate {
  const SkillContextUpdate(this.snapshot, this.text);
  final Json snapshot;
  final String? text;
  ConversationItem? get item => text == null ? null : ConversationItem(
    role: 'developer', content: [{'type': 'text', 'text': text}],
    native: {'harness': {'context': 'skills'}},
  );
}

/// The complete inventory and accounting stay in task metadata, never in a
/// ConversationItem. Only bounded presentation text is sent to a model.
SkillContextUpdate skillContext(Json catalog, {
  Json? previous, int? contextWindow, int? maxTokens,
}) {
  final budget = SkillBudget(contextWindow: contextWindow, maxTokens: maxTokens);
  if (previous?['version'] != 1) previous = null;
  final before = jsonObject(previous?['entries'] ?? {});
  final all = (catalog['skills'] as List? ?? []).map(jsonObject).toList();
  final visible = all.where((skill) => skill['implicit'] != false).toList();
  final entries = <String, dynamic>{};
  for (final skill in all) {
    final path = skill['path'] as String;
    entries[path] = {
      'fingerprint': sha256.convert(utf8.encode(jsonEncode([
        skill['name'], skill['description'], skill['path'], skill['implicit'],
      ]))).toString(),
      'shown': skill['implicit'] != false && before[path]?['shown'] == true,
    };
  }
  var usedTokens = previous?['tokens'] as int? ?? 0;
  var usedCharacters = previous?['characters'] as int? ?? 0;
  final remaining = budget.limit - (budget.tokens ? usedTokens : usedCharacters);
  final initial = previous?['initialized'] != true;
  final aliases = Map<String, String>.from(previous?['roots'] as Map? ?? {});
  final candidates = visible.where((skill) {
    final path = skill['path'] as String;
    return initial || before[path] == null ||
      before[path]['fingerprint'] != entries[path]['fingerprint'];
  }).toList();
  final removed = before.keys.where((path) =>
    before[path]['shown'] == true && (entries[path] == null ||
      !visible.any((skill) => skill['path'] == path)),
  ).toList();
  final errorCount = catalog['error_count'] as int? ?? 0;
  if (initial && aliases.isEmpty && visible.isNotEmpty) {
    final roots = visible.map((skill) => skill['root'] as String).toSet().toList()..sort();
    var index = 0;
    for (final root in roots) {
      final paths = visible.map((skill) => skill['path'] as String)
        .where((path) => path.startsWith('$root/')).toList();
      final alias = 'r$index';
      // Include a root mapping only when it saves more than its own overhead.
      if (paths.length * (root.length - alias.length) > root.length + alias.length + 8) {
        aliases[alias] = root;
        index++;
      }
    }
  }
  String locator(String path) {
    final matching = aliases.entries.where((entry) => path.startsWith(entry.value + '/')).toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return matching.isEmpty ? path : matching.first.key + path.substring(matching.first.value.length);
  }
  final rows = [
    for (final path in removed) _SkillLine.removed(path, locator(path)),
    for (final skill in candidates) _SkillLine(
      skill['path'] as String, skill['name'] as String,
      locator(skill['path'] as String), skill['description'] as String,
    ),
  ];
  final diagnosticsChanged = errorCount != (previous?['error_count'] ?? 0);
  String? text;
  if (remaining > 0 && (rows.isNotEmpty || diagnosticsChanged && errorCount > 0)) {
    final prefix = initial ? [
      '<skills_instructions>',
      '## Skills',
      'Skills are local instructions in SKILL.md files. Use a skill when the user names it or the task matches its description.',
      'Read the selected SKILL.md completely before acting. Resolve its relative paths against the containing directory. Load supporting files only as needed.',
      'Use the skill tool when available, with the expanded file path as its id; otherwise use file tools. Read the skill again if its instructions are no longer in context.',
      if (aliases.isNotEmpty) ...[
        '### Skill roots',
        'Expand each short path using these roots:',
        for (final entry in aliases.entries) '- ' + entry.key + ': ' + entry.value,
      ],
      '### Available skills',
    ].join('\n') + '\n' : '<skills_instructions>\n### Added or updated skills\n'
      'Each entry replaces the earlier entry for the same file. Removed files must no longer be used.\n';
    // Reserve the omission notice before allocating. It also explains where
    // descriptions went without repeating the complete inventory.
    final notice = 'Descriptions may be shortened; some skills may be omitted to fit the context budget.\n';
    final suffix = (errorCount > 0 ? '$errorCount skill files or directories could not be loaded.\n' : '')
      + notice + '</skills_instructions>';
    var available = remaining - budget.cost(prefix + suffix);
    final selected = <_SkillLine>[];
    for (final row in rows) {
      final cost = budget.cost(row.render(0) + '\n');
      if (cost <= available) {
        selected.add(row);
        available -= cost;
      }
    }
    final allocations = List<int>.filled(selected.length, 0);
    // Match Codex's fair description allocation, without splitting Unicode
    // scalars. Cached prefix byte counts keep large catalogs linear per pass.
    while (available > 0) {
      var changed = false;
      for (var i = 0; i < selected.length; i++) {
        final row = selected[i], length = allocations[i];
        if (length == row.description.length) continue;
        final delta = row.cost(length + 1, budget) - row.cost(length, budget);
        if (delta <= available) {
          allocations[i]++;
          available -= delta;
          changed = true;
        }
      }
      if (!changed) break;
    }
    if (selected.isNotEmpty || diagnosticsChanged && errorCount > 0 && available >= 0) {
      final rendered = prefix + [
        for (var i = 0; i < selected.length; i++) selected[i].render(allocations[i]),
      ].join('\n') + (selected.isEmpty ? '' : '\n') + suffix;
      if (budget.cost(rendered) <= remaining) {
        text = rendered;
        for (final row in selected) {
          if (entries[row.path] != null && !row.removed) entries[row.path]['shown'] = true;
        }
        usedTokens += (utf8.encode(text).length + 3) ~/ 4;
        usedCharacters += text.runes.length;
      }
    }
  }
  return SkillContextUpdate({
    'version': 1, 'entries': entries, 'roots': aliases,
    'tokens': usedTokens, 'characters': usedCharacters,
    'initialized': !initial || text != null, 'error_count': errorCount,
  }, text);
}

class _SkillLine {
  _SkillLine(this.path, String name, String locator, String description)
    : base = '- $name', tail = ' (file: $locator)', removed = false,
      description = description.runes.take(1024).toList() {
    _bytes.add(0);
    for (final rune in this.description) {
      _bytes.add(_bytes.last + (rune <= 0x7f ? 1 : rune <= 0x7ff ? 2 : rune <= 0xffff ? 3 : 4));
    }
    _baseBytes = utf8.encode(base + tail + '\n').length;
    _baseChars = (base + tail + '\n').runes.length;
  }
  _SkillLine.removed(this.path, String locator)
    : base = '- Removed skill file: $locator', tail = '', removed = true, description = [] {
    _bytes.add(0);
    _baseBytes = utf8.encode(base + '\n').length;
    _baseChars = (base + '\n').runes.length;
  }
  final String path, base, tail;
  final bool removed;
  final List<int> description;
  final _bytes = <int>[];
  late final int _baseBytes, _baseChars;
  int cost(int count, SkillBudget budget) {
    final punctuation = count == 0 ? 0 : 2 + (count < description.length ? 3 : 0);
    return budget.tokens ? (_baseBytes + _bytes[count] + punctuation + 3) ~/ 4
      : _baseChars + count + punctuation;
  }
  String render(int count) => base + (count == 0 ? ''
    : ': ' + String.fromCharCodes(description.take(count)) + (count < description.length ? '...' : '')) + tail;
}
