import 'package:flutter/painting.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:val_highlight/languages/all.dart' as fast;
import 'package:val_highlight/val_highlight.dart' as fast;

final _languages = fast.LanguageRegistry(fast.allLanguages);
final _scanner = fast.Highlighter(registry: _languages);
// Dart initializes top-level fields lazily: common languages never construct
// the much larger Highlight.js grammar registry.
final _fallback = Highlight()..registerLanguages(builtinAllLanguages);
final _scopeSuffix = RegExp(r'_+(?=\.|$)');
final _theme = {
  for (final entry in githubTheme.entries)
    entry.key.replaceAll(_scopeSuffix, ''): entry.value,
  'function': githubTheme['title.function_']!,
  'type.builtin': githubTheme['built_in']!,
  'property': githubTheme['attr']!,
  'tag': githubTheme['name']!,
  'heading': githubTheme['section']!,
  'interpolation': githubTheme['subst']!,
};
final _spans = <(String, String), TextSpan>{};
int _cachedCharacters = 0;

/// Highlights immutable source using an explicit language ID or its alias.
/// Cached spans survive transcript rebuilds and lazy row disposal. Output is
/// separate from source and never participates in parsing or cache invalidation.
TextSpan highlightedCode(String source, {required String language}) {
  final plain = TextSpan(text: source);
  // Bound synchronous parser work; large/minified snippets remain selectable.
  if (source.isEmpty || source.length > 128 * 1024 || language.isEmpty) return plain;
  final key = (language.trim().toLowerCase(), source);
  final cached = _spans.remove(key);
  if (cached != null) {
    _spans[key] = cached;
    return cached;
  }

  var span = plain;
  try {
    final grammar = _languages.lookup(key.$1);
    if (grammar != null) {
      span = _scanCode(source, grammar);
    } else if (source.length <= 16 * 1024 &&
        !source.split('\n').any((line) => line.length > 2000) &&
        _fallback.getLanguage(key.$1) != null) {
      final result = _fallback.highlight(code: source, language: key.$1);
      if (!result.illegal && result.errorRaised == null) {
        final renderer = _CodeRenderer();
        result.render(renderer);
        final highlighted = TextSpan(children: renderer.spans);
        // A grammar error must never drop or normalize conversation text.
        if (highlighted.toPlainText() == source) {
          span = highlighted;
        }
      }
    }
  } catch (_) {
    // Highlighting is optional; malformed source still renders verbatim.
  }

  _spans[key] = span;
  _cachedCharacters += source.length;
  while (_spans.length > 128 || _cachedCharacters > 256 * 1024) {
    final oldest = _spans.keys.first;
    _spans.remove(oldest);
    _cachedCharacters -= oldest.$2.length;
  }
  return span;
}

TextStyle? _scopeStyle(String? scope) {
  while (scope != null) {
    final style = _theme[scope];
    if (style != null) return style;
    final dot = scope.lastIndexOf('.');
    scope = dot < 0 ? null : scope.substring(0, dot);
  }
  return null;
}

TextSpan _scanCode(String source, fast.Grammar grammar) {
  final result = _scanner.highlight(source, language: grammar);
  if (result.tokenCount == 0 || result.tokenEnd(result.tokenCount - 1) != source.length) {
    return TextSpan(text: source);
  }
  // Resolve each interned scope stack once, instead of once per token.
  final table = result.scopes;
  final styles = List<TextStyle?>.filled(table.stackCount, null);
  for (var stack = 1; stack < styles.length; stack++) {
    final style = _scopeStyle(table.scopeOf(stack));
    styles[stack] = styles[table.parentOf(stack)]?.merge(style) ?? style;
  }
  final spans = <TextSpan>[];
  var start = 0;
  TextStyle? style = styles[result.tokenStack(0)];
  for (var token = 1; token < result.tokenCount; token++) {
    final next = styles[result.tokenStack(token)];
    if (next == style) continue;
    final end = result.tokenStart(token);
    spans.add(TextSpan(text: source.substring(start, end), style: style));
    start = end;
    style = next;
  }
  spans.add(TextSpan(text: source.substring(start), style: style));
  return TextSpan(children: spans);
}

// Build flat spans with inherited scope styles. The package's renderer copies
// its parent's children for every token and misses dotted scopes in its themes.
class _CodeRenderer implements HighlightRenderer {
  final spans = <TextSpan>[];
  final _styles = <TextStyle?>[];

  @override
  void addText(String text) => spans.add(TextSpan(text: text, style: _styles.lastOrNull));

  @override
  void openNode(DataNode node) {
    final style = _scopeStyle(node.scope);
    _styles.add(_styles.lastOrNull?.merge(style) ?? style);
  }

  @override
  void closeNode(DataNode node) => _styles.removeLast();
}
