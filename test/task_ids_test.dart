import 'dart:math';

import 'package:openai/src/task_id.dart' as openai;
import 'package:opencode/src/task_id.dart' as opencode;
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('Codex task IDs are UUIDv7 and remain ordered within a millisecond and after clock rollback', () {
    // Timestamp from uuid 1.20.0's v7 test_new, pinned by Codex.
    var time = 1645557742000;
    final ids = openai.TaskIds(clock: () => time, random: Random(7));
    final generated = List.generate(2000, (_) => ids.create());
    expect(generated, everyElement(matches(r'^017f22e2-79b0-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    time -= 1000;
    generated.add(ids.create());
    time += 2000;
    generated.add(ids.create());
    expect(generated.toSet(), hasLength(generated.length));
    expect(generated, orderedEquals([...generated]..sort()));
    expect(generated.last, startsWith('017f22e2-7d98-7'));
  });

  test('OpenCode task IDs match the captured upstream descending identifier and byte mapping', () {
    var time = 1000;
    final ids = opencode.TaskIds(clock: () => time, random: _Bytes());
    // Executed packages/schema/src/identifier.ts at e8238bae with timestamp
    // 1000, 1000, 1001 and crypto bytes cycling through 0, 61, 62, 255.
    expect(ids.create(), 'ses_ffffffc17ffe0z070z070z070z');
    expect(ids.create(), 'ses_ffffffc17ffd070z070z070z07');
    time++;
    expect(ids.create(), 'ses_ffffffc16ffe0z070z070z070z');
    final generated = List.generate(5000, (_) => ids.create());
    expect(generated.toSet(), hasLength(5000));
    expect(generated, orderedEquals([...generated]..sort((a, b) => b.compareTo(a))));
    expect(generated, everyElement(matches(r'^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$')));
  });

  test('task ID validation accepts provider and legacy IDs while rejecting unsafe path components', () {
    for (final id in [newId(), openai.TaskIds().create(), opencode.TaskIds().create()]) {
      expect(() => validateTaskId(id), returnsNormally);
    }
    for (final id in ['', '.', '..', '../escape', r'..\escape', '/absolute', 'a/b', 'a\nb', 'a' * 129]) {
      expect(() => validateTaskId(id), throwsFormatException, reason: id);
    }
  });
}

class _Bytes implements Random {
  int _index = 0;
  @override
  int nextInt(int max) { expect(max, 256); return [0, 61, 62, 255][_index++ % 4]; }
  @override
  bool nextBool() => throw UnsupportedError('Only byte generation is expected');
  @override
  double nextDouble() => throw UnsupportedError('Only byte generation is expected');
}
