import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final directory = File.fromUri(Platform.script).parent;
  File('${directory.path}/starts').writeAsStringSync('${jsonEncode({
    'pid': pid,
    'moon': Platform.environment.keys.where((key) => key.startsWith('MOON_')).toList(),
    'sentinel': Platform.environment['HAPPEN_LAUNCH_SENTINEL'],
    'PATH': Platform.environment['PATH'],
    'FLUTTER_ROOT': Platform.environment['FLUTTER_ROOT'],
  })}\n', mode: FileMode.append, flush: true);
  await for (final bytes in stdin) {
    for (final byte in bytes) {
      if (byte == 113) return; // q
      if (byte == 120) exit(42); // x
      stdout.writeln('received:${String.fromCharCode(byte)}');
    }
  }
}
