import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final directory = File.fromUri(Platform.script).parent;
  final workspace = arguments.firstOrNull == 'pub' ? Directory.current : Directory.current.parent.parent;
  final packageFile = File('${workspace.path}/.dart_tool/package_config.json');
  final packages = jsonDecode(await packageFile.readAsString()) as Map<String, dynamic>;
  final framework = (packages['packages'] as List).cast<Map<String, dynamic>>()
    .singleWhere((package) => package['name'] == 'flutter');
  if (arguments.firstOrNull == 'pub') {
    framework['rootUri'] = Uri.directory('${Platform.environment['FLUTTER_ROOT']}/packages/flutter').toString();
    await packageFile.writeAsString(jsonEncode(packages));
    return;
  }
  final starts = Directory('${directory.path}/starts')..createSync();
  final pending = File('${starts.path}/$pid.tmp');
  pending.writeAsStringSync(jsonEncode({
    'pid': pid,
    'moon': Platform.environment.keys.where((key) => key.startsWith('MOON_')).toList(),
    'sentinel': Platform.environment['HAPPEN_LAUNCH_SENTINEL'],
    'PATH': Platform.environment['PATH'],
    'FLUTTER_ROOT': Platform.environment['FLUTTER_ROOT'],
    'frameworkRoot': Directory.fromUri(packageFile.uri.resolve(framework['rootUri'] as String)).resolveSymbolicLinksSync(),
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
