import 'package:desktop/code_highlight.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('explicit languages and aliases preserve source, including embedded code and diffs', () {
    for (final (language, source) in [
      ('JS', '// 🙂\r\n' r'const value = `answer: ${42}`;' '\r\nawait Promise.resolve(/a+/g);'),
      ('javascript', r'const unfinished = `value: ${'),
      ('dart', "final value = <String>['hello'];"),
      ('ts', 'interface Value { count: number; }'),
      ('py', 'def greet():\n    return "hello"\n'),
      ('html', '<div>Hello</div><script>const value = 42;</script>'),
      ('diff', '--- a/file.js\n+++ b/file.js\n@@ -1 +1 @@\n-const x = 1;\n+const x = 2;\n'),
      ('fortran', 'program hello\n  print *, "hello"\nend program hello\n'),
    ]) {
      final span = highlightedCode(source, language: language);
      expect(span.toPlainText(), source, reason: language);
      expect(_hasColor(span), isTrue, reason: language);
    }
  });

  test('unknown languages and oversized source remain readable verbatim', () {
    for (final (language, source) in [
      ('not-a-language', 'const value = "🙂";\r\n'),
      ('javascript', 'const value = 42;\n' * 8000),
      ('fortran', 'a' * 2001),
      ('javascript', ''),
    ]) {
      final span = highlightedCode(source, language: language);
      expect(span.toPlainText(), source);
      expect(_hasColor(span), isFalse);
    }
  });
}

bool _hasColor(TextSpan span) {
  var colored = false;
  span.visitChildren((child) {
    if (child.style?.color != null) colored = true;
    return true;
  });
  return colored;
}
