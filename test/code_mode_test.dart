import 'dart:async';
import 'dart:convert';

import 'package:code_mode/code_mode.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('code-mode cell lifecycle', () {
    test(
      'only explicit JSON state crosses cells; host calls are concurrent',
      () async {
        const mode = CodeMode();
        final entered = <String>[];
        final gate = Completer<void>();
        final result = await mode.execute(
          '''
        globalThis.accidental = 99;
        const values = await Promise.all([tools.first({}), tools.second({})]);
        store("answer", values[0] + values[1]);
        text(load("answer"));
      ''',
          cancellation: CancellationToken(),
          tool: (name, _) async {
            entered.add(name);
            if (entered.length == 2) gate.complete();
            await gate.future;
            return name == 'first' ? 19 : 23;
          },
        );
        expect(result['output'], ['42']);
        final next = await mode.execute(
          'text([typeof accidental, load("answer")]);',
          values: jsonObject(result['values']),
          cancellation: CancellationToken(),
          tool: (_, _) async => throw StateError('unexpected host call'),
        );
        expect(next['output'], ['["undefined",42]']);
      },
    );

    test(
      'large batched output is truncated without aborting the cell',
      () async {
        final result = await const CodeMode().execute(
          '''
          const results = await Promise.allSettled([tools.first({}), tools.second({})]);
          for (const result of results) text(result.value.output);
          store("complete", true);
          text("finished");
          ''',
          cancellation: CancellationToken(),
          tool: (name, _) async => {
            'output': name == 'first'
                ? 'begin:${'a' * 39994}'
                : '${'b' * 39996}end!',
          },
        );
        expect(result['values'], {'complete': true});
        final output = (result['output'] as List).single as String;
        const header = 'Warning: truncated output (original token count: 20003)\n'
            'Total output lines: 3\n\n';
        const marker = '…10003 tokens truncated…';
        expect(output, startsWith('${header}begin:${'a' * 19994}'));
        expect(output, contains(marker));
        expect(output, endsWith('${'b' * 19987}end!\nfinished'));
        expect(output.length, 40000 + header.length + marker.length);
      },
    );

    test(
      'output budgets support overrides, zero, and UTF-8 boundaries',
      () async {
        final cases = <({String source, List<String> output})>[
          (source: 'text("x".repeat(40000));', output: ['x' * 40000]),
          (
            source: '// @exec: {"max_output_tokens": 20000}\ntext("x".repeat(70000));',
            output: ['x' * 70000],
          ),
          (
            source: '// @exec: {"max_output_tokens": null}\ntext("x".repeat(40001));',
            output: ['Warning: truncated output (original token count: 10001)\n'
                'Total output lines: 1\n\n${'x' * 20000}…1 tokens truncated…${'x' * 20000}'],
          ),
          (
            source: '// @exec: {"max_output_tokens": 0}\ntext("hidden");',
            output: ['Warning: truncated output (original token count: 2)\n'
                'Total output lines: 1\n\n…2 tokens truncated…'],
          ),
          (
            source: '\t// @exec: {"max_output_tokens": 3}\r\ntext("😀".repeat(17));',
            output: ['Warning: truncated output (original token count: 17)\n'
                'Total output lines: 1\n\n😀…14 tokens truncated…😀'],
          ),
          (
            source: '// @exec: {"max_output_tokens": 1}\ntext("ab"); text("cd");',
            output: ['Warning: truncated output (original token count: 2)\n'
                'Total output lines: 2\n\nab…1 tokens truncated…cd'],
          ),
        ];
        for (final item in cases) {
          final result = await const CodeMode().execute(
            item.source,
            cancellation: CancellationToken(),
            tool: (_, _) async => throw StateError('unexpected host call'),
          );
          expect(result['output'], item.output, reason: item.source);
        }
      },
    );

    test('invalid output pragmas fail before executing host calls', () async {
      var calls = 0;
      for (final directive in [
        '{"max_output_tokens": -1}',
        '{"max_output_tokens": 1.5}',
        '{"max_output_tokens": "10"}',
        '{"max_output_tokens": 9007199254740992}',
        '{"unknown": 10}',
        '[]',
        '{',
      ]) {
        await expectLater(
          const CodeMode().execute(
            '// @exec: $directive\nawait tools.side_effect({});',
            cancellation: CancellationToken(),
            tool: (_, _) async => calls++,
          ),
          throwsFormatException,
          reason: directive,
        );
      }
      expect(calls, 0);
    });

    test('retention bounds keep a rolling tail and report lost output', () async {
      for (final text in ['x', '😀']) {
        final result = await const CodeMode().execute(
          '''
          text(${jsonEncode(text)}.repeat(${text == 'x' ? 2097152 : 524288}));
          text("last");
          store("complete", true);
          ''',
          cancellation: CancellationToken(),
          tool: (_, _) async => throw StateError('unexpected host call'),
        );
        expect(result['values'], {'complete': true});
        final output = (result['output'] as List).cast<String>();
        expect(output.first, startsWith('Warning: truncated output (original token count: 262145)\n'
            'Total output lines: 2\n\n'));
        expect(output.join(), contains('Code Mode session output limit reached: '
            'omitted 1048580 text bytes'));
        expect(output.last, endsWith('last'));
        expect(output.join(), isNot(contains('\uFFFD')));
      }
    });

    test('retained text and item counts match Codex caps', () async {
      final bytes = await const CodeMode().execute(
        '// @exec: {"max_output_tokens": 9007199254740991}\n'
        'text("x".repeat(2097152)); text("last");',
        cancellation: CancellationToken(),
        tool: (_, _) async => throw StateError('unexpected host call'),
      );
      final output = (bytes['output'] as List).cast<String>();
      expect(output, [
        'x' * 524288,
        '[Code Mode session output limit reached: omitted 1048580 text bytes; '
            'discarded 0 text segments, 0 images, 0 audio items]',
        'x' * 524284,
        'last',
      ]);
      expect(output.where((text) => !text.startsWith('[Code Mode'))
          .fold<int>(0, (bytes, text) => bytes + utf8.encode(text).length), 1048576);
      final items = await const CodeMode().execute(
        '// @exec: {"max_output_tokens": 100000}\n'
        'for (let i = 0; i < 32769; i++) text(String(i));',
        cancellation: CancellationToken(),
        tool: (_, _) async => throw StateError('unexpected host call'),
      );
      final retained = items['output'] as List;
      expect(retained, hasLength(32768));
      expect(retained.first, '0');
      expect(retained[16384], '[Code Mode session output limit reached: omitted 10 text bytes; '
          'discarded 2 text segments, 0 images, 0 audio items]');
      expect(retained.last, '32768');
    });

    test(
      'CPU deadline interrupts a runaway cell without poisoning the next',
      () async {
        const mode = CodeMode(cpuBudgetMs: 30);
        await expectLater(
          mode.execute(
            'while (true) {}',
            tool: (_, _) async => null,
            cancellation: CancellationToken(),
          ),
          throwsStateError,
        );
        final next = await mode.execute(
          'text(42);',
          tool: (_, _) async => null,
          cancellation: CancellationToken(),
        );
        expect(next['output'], ['42']);
      },
    );

    test(
      'cancellation releases a cell awaiting an unresolved host operation',
      () async {
        final cancellation = CancellationToken();
        final entered = Completer<void>(), operation = Completer<Object?>();
        final running = const CodeMode().execute(
          'await tools.wait({});',
          cancellation: cancellation,
          tool: (_, _) {
            entered.complete();
            return operation.future;
          },
        );
        await entered.future;
        cancellation.cancel();
        await expectLater(running, throwsA(isA<CancelledException>()));
        operation.complete(null);
      },
    );
  });
}
