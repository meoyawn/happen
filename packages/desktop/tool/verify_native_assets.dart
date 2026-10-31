import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

// Run after `flutter build macos --debug`. Only a temporary copy is replaced;
// the built application and any running instance are left intact.
Future<void> main(List<String> args) async {
  if (!Platform.isMacOS) throw UnsupportedError('This check requires macOS');
  final app = Directory(args.isEmpty
      ? Platform.script.resolve('../build/macos/Build/Products/Debug/Happen.app').toFilePath()
      : args.single).absolute;
  final frameworks = '${app.path}/Contents/Frameworks';
  final manifest = jsonDecode(await File(
    '$frameworks/App.framework/Resources/flutter_assets/NativeAssetsManifest.json',
  ).readAsString()) as Map<String, dynamic>;
  final target = Abi.current() == Abi.macosArm64 ? 'macos_arm64' : 'macos_x64';
  final location = manifest['native-assets'][target]
      ['package:sqlite3/src/ffi/libsqlite3.g.dart'] as List<dynamic>;
  if (location[0] != 'absolute') throw StateError('Expected bundled SQLite');
  final loadPath = location[1] as String;
  final temporary = await Directory.systemTemp.createTemp('happen-native-assets-');
  try {
    final probe = File('${temporary.path}/Contents/MacOS/probe');
    await probe.parent.create(recursive: true);
    final copies = Directory('${temporary.path}/Contents/Frameworks');
    await copies.create(recursive: true);
    await _run('ditto', ['$frameworks/sqlite3.framework', '${copies.path}/sqlite3.framework']);
    await _run('xcrun', [
      'clang', '-Wall', '-Wextra', '-Werror',
      Platform.script.resolve('native_assets_probe.c').toFilePath(),
      '-Wl,-rpath,@executable_path/../Frameworks', '-o', probe.path,
    ]);
    final library = await File('${copies.path}/sqlite3.framework/sqlite3').resolveSymbolicLinks();
    await _run(probe.path, [loadPath, library],
      workingDirectory: copies.path);
  } finally {
    await temporary.delete(recursive: true);
  }
}

Future<void> _run(String executable, List<String> args, {String? workingDirectory}) async {
  final result = await Process.run(executable, args, workingDirectory: workingDirectory);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) throw ProcessException(executable, args, 'Native asset check failed', result.exitCode);
}
