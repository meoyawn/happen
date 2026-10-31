import 'dart:math';

// SessionID.create -> "ses_" + Identifier.descending() in the pinned schema.
class TaskIds {
  TaskIds({int Function()? clock, Random? random})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random.secure();
  final int Function() _clock;
  final Random _random;
  int _timestamp = 0, _counter = 0;
  static const _chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  String create() {
    final now = _clock();
    if (now != _timestamp) { _timestamp = now; _counter = 0; }
    _counter++;
    final time = (~(now * 0x1000 + _counter) & 0xffffffffffff)
      .toRadixString(16).padLeft(12, '0');
    final suffix = List.generate(14, (_) => _chars[_random.nextInt(256) % 62]).join();
    return 'ses_$time$suffix';
  }
}

final taskIds = TaskIds();
