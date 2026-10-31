// Run with: flutter test tool/bench_code_highlight.dart --no-pub --reporter expanded
import 'package:desktop/code_highlight.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('immutable code highlighting benchmark', () {
    const sample = '// sample\nconst value = await tools.exec_command({cmd: "ls", max_output_tokens: 1000});\ntext(value);\n';
    final watch = Stopwatch()..start();
    final first = highlightedCode(sample, language: 'javascript');
    final cold = watch.elapsedMicroseconds;
    expect(first.toPlainText(), sample);
    print('Cold registry/JavaScript parse/render: $cold us');

    var serial = 0;
    // Warm the scanner independently of the immutable span cache.
    for (var i = 0; i < 100; i++) {
      highlightedCode('$sample// ${serial++}', language: 'javascript');
    }
    for (final repeats in [1, 10, 80, 320, 1000]) {
      final source = sample * repeats;
      final times = <int>[];
      for (var i = 0; i < 21; i++) {
        final unique = '$source// ${serial++}';
        watch.reset();
        final span = highlightedCode(unique, language: 'javascript');
        times.add(watch.elapsedMicroseconds);
        expect(span.toPlainText(), unique);
      }
      times.sort();
      TextSpan cached = highlightedCode(source, language: 'javascript');
      watch.reset();
      for (var i = 0; i < 10000; i++) {
        cached = highlightedCode(source, language: 'javascript');
      }
      final hit = watch.elapsedMicroseconds / 10000;
      expect(cached.toPlainText(), source);
      print('${source.length} chars: miss median ${times[10]} us, cached ${hit.toStringAsFixed(2)} us');
    }
  });
}
