/// Fixed-name counters and bounded histograms. No network, timers, or SDK.
class Telemetry {
  Telemetry({this.enabled = true});
  final bool enabled;
  final _counters = <String, num>{};
  final _timings = <String, _Timing>{};

  void add(String name, [num value = 1]) {
    if (enabled)
      _counters.update(name, (n) => n + value, ifAbsent: () => value);
  }

  void observe(String name, Duration duration) {
    if (enabled) {
      _timings.putIfAbsent(name, _Timing.new).add(duration.inMicroseconds);
    }
  }

  Map<String, Object> snapshot() => {
    'counters': Map.of(_counters),
    'timings_us': _timings.map((key, value) => MapEntry(key, value.json())),
  };
}

class _Timing {
  static const bounds = [100, 1000, 10000, 100000, 1000000, 10000000];
  final buckets = List<int>.filled(bounds.length + 1, 0);
  int count = 0, total = 0, max = 0;
  void add(int value) {
    count++;
    total += value;
    if (value > max) max = value;
    final index = bounds.indexWhere((limit) => value <= limit);
    buckets[index < 0 ? bounds.length : index]++;
  }

  Map<String, Object> json() => {
    'count': count,
    'sum': total,
    'max': max,
    'bounds': bounds,
    'buckets': List.of(buckets),
  };
}
