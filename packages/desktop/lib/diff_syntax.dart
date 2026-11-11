import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:shiki_flutter/shiki_flutter.dart' as shiki;

import 'package:protocol/protocol.dart';

import 'diff_patch.dart';

/// Token ranges belong to a specific patch. No parsing happens while scrolling
/// or composing word-change backgrounds, and no full-file/network read is needed.
class DiffSyntax {
  DiffSyntax._(this._lines);
  final Map<(int?, int?), List<_Token>> _lines;

  TextSpan span(DiffCodeLine line, String text, { (int, int)? changed, Color? background }) {
    final tokens = _lines[(line.oldLine, line.newLine)] ?? [_Token(0, text.length, null)];
    final spans = <TextSpan>[];
    for (final token in tokens) {
      var start = token.start;
      while (start < token.end) {
        var end = token.end;
        if (changed != null) {
          if (start < changed.$1) { end = end.clamp(start, changed.$1); }
          else if (start < changed.$2) { end = end.clamp(start, changed.$2); }
        }
        final style = token.style ?? TextStyle(color: token.color);
        spans.add(TextSpan(text: text.substring(start, end), style: style.copyWith(
          backgroundColor: changed != null && start >= changed.$1 && start < changed.$2 ? background : null)));
        start = end;
      }
    }
    return TextSpan(children: spans);
  }
}

class _Token {
  const _Token(this.start, this.end, this.color, [this.style]);
  final int start, end;
  final Color? color;
  final TextStyle? style;
}

/// Compiled grammars and the warm background isolate have the viewer's lifetime.
/// File bytes remain bounded here and rendered ranges stay with each patch.
class DiffHighlighter {
  final identity = Object();
  final _engine = shiki.ShikiHighlighter(cache: shiki.TokenCache(maxEntries: 16, maxChars: 256 * 1024))
    ..ensureShikiTheme(shiki.PierreThemes.pierreLight);
  bool _disposed = false;

  static final _languages = <String, shiki.CodeLanguage>{
    for (final language in shiki.CodeLanguages.all) ...{
      language.id.toLowerCase(): language,
      for (final alias in language.aliases) alias.toLowerCase(): language,
    },
  };

  static shiki.CodeLanguage? _language(String path) {
    final name = p.posix.basename(path).toLowerCase();
    final extension = p.posix.extension(name).replaceFirst('.', '');
    final candidate = switch (name) {
      'dockerfile' => 'dockerfile', 'makefile' || 'gnumakefile' => 'make',
      'cmakelists.txt' => 'cmake', '.gitignore' || '.gitattributes' => 'plaintext',
      '.bashrc' || '.bash_profile' || '.zshrc' || '.zprofile' => 'shellscript',
      _ => switch (extension) {
        'h' => 'c', 'hpp' || 'hh' || 'hxx' || 'cc' || 'cxx' => 'cpp',
        'mjs' || 'cjs' => 'javascript', 'mts' || 'cts' => 'typescript',
        'tf' || 'tfvars' => 'terraform', 'svg' || 'plist' || 'xaml' => 'xml',
        'sh' || 'zsh' || 'bash' => 'shellscript', 'jsonl' => 'json',
        'lock' => name == 'pubspec.lock' ? 'yaml' : 'plaintext',
        _ => extension,
      },
    };
    return _languages[candidate];
  }

  Future<DiffSyntax> highlight(DiffPatch patch, String path, String? previousPath, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    final result = DiffSyntax._({});
    // Bound both parser work and the derived cache. Large previews remain plain.
    if (_disposed || patch.raw.length > 256 * 1024) return result;
    final oldLanguage = _language(previousPath ?? path), newLanguage = _language(path);
    if (oldLanguage == null && newLanguage == null) return result;
    for (final hunk in patch.hunks) {
      cancellation.throwIfCancelled();
      Future<void> side(bool old, shiki.CodeLanguage? language) async {
        if (_disposed || language == null) return;
        final lines = hunk.lines.where((line) => old ? line.kind != DiffLineKind.addition : line.kind != DiffLineKind.deletion).toList();
        final texts = lines.map((line) => expandDiffTabs(line.text)).toList();
        final source = texts.join('\n');
        if (source.isEmpty) return;
        try {
          _engine.ensureLanguage(language);
          final highlighted = await _engine.codeToTokensAsync(source, shiki.TokenizeOptions(
            lang: language.id, theme: shiki.PierreThemes.pierreLight.id, tokenizeMaxLineLength: 1000)).asCancellable(cancellation);
          cancellation.throwIfCancelled();
          if (_disposed || highlighted.length != lines.length) return;
          for (var i = 0; i < lines.length; i++) {
            final themed = highlighted[i];
            // Preserve every source code unit, including CRLF or malformed text
            // that a tokenizer might normalize. An incomplete line stays plain.
            if (themed.map((token) => token.content).join() != texts[i]) continue;
            var offset = 0;
            final tokens = <_Token>[];
            for (final token in themed) {
              final end = offset + token.content.length;
              tokens.add(_Token(offset, end, null, shiki.themedTokenStyle(token)));
              offset = end;
            }
            final line = lines[i];
            if (!old || line.kind == DiffLineKind.deletion || newLanguage == null) result._lines[(line.oldLine, line.newLine)] = tokens;
          }
        } on CancelledException {
          rethrow;
        } catch (_) {
          // An unsupported grammar or malformed snippet must never hide the diff.
        }
      }
      await side(true, oldLanguage); await side(false, newLanguage);
    }
    return result;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _engine.dispose();
  }
}

String expandDiffTabs(String text) {
  if (!text.contains('\t')) return text;
  final buffer = StringBuffer(); var column = 0;
  for (final rune in text.runes) {
    if (rune == 9) { final count = 4 - column % 4; buffer.write(' ' * count); column += count; }
    else { buffer.writeCharCode(rune); column++; }
  }
  return buffer.toString();
}
