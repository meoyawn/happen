import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final directory = File.fromUri(Platform.script).parent;
  final starts = Directory('${directory.path}/starts')..createSync();
  final pending = File('${starts.path}/$pid.tmp');
  pending.writeAsStringSync(jsonEncode({
    'pid': pid,
    'moon': Platform.environment.keys.where((key) => key.startsWith('MOON_')).toList(),
    'sentinel': Platform.environment['HAPPEN_LAUNCH_SENTINEL'],
    'PATH': Platform.environment['PATH'],
    'FLUTTER_ROOT': Platform.environment['FLUTTER_ROOT'],
  }), flush: true);
  pending.renameSync('${starts.path}/$pid.json');
  await for (final bytes in stdin) {
    for (final byte in bytes) {
      if (byte == 113) return; // q
      if (byte == 120) exit(42); // x
      stdout.writeln('received:${String.fromCharCode(byte)}');
    }
  }
}
