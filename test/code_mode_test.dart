import 'dart:async';

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
