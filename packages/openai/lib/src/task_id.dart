import 'dart:math';

// Codex ThreadId::new uses uuid::Uuid::now_v7: millisecond time and a
// reseeded 42-bit counter keep IDs ordered even when the clock moves back.
class TaskIds {
  TaskIds({int Function()? clock, Random? random})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random.secure();
  final int Function() _clock;
  final Random _random;
  int _timestamp = 0, _counter = 0;

  String create() {
    final now = _clock();
    if (now > _timestamp || _counter == 0x3ffffffffff) {
      _timestamp = now > _timestamp ? now : _timestamp + 1;
      _counter = _random.nextInt(1 << 21) * (1 << 20) + _random.nextInt(1 << 20);
    } else {
      _counter++;
    }
    String hex(int value, int width) => value.toRadixString(16).padLeft(width, '0');
    final time = hex(_timestamp, 12);
    return '${time.substring(0, 8)}-${time.substring(8)}-'
      '${hex(0x7000 | _counter >> 30, 4)}-'
      '${hex(0x8000 | (_counter >> 16 & 0x3fff), 4)}-'
      '${hex(_counter & 0xffff, 4)}${hex(_random.nextInt(1 << 32), 8)}';
  }
}

final taskIds = TaskIds();
