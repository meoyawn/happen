import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../cli_native_bootstrap.dart' show linuxNativeContracts;
import 'common.dart';

const _libraries = {
  'code_mode': 'libcode_mode.so',
  'sqlite3': 'libsqlite3.so',
  'flutter_pty2': 'libflutter_pty2.so',
};

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || !_libraries.containsKey(arguments[0])) {
    throw ArgumentError('Usage: dart tool/build_server/native.dart <code_mode|sqlite3|flutter_pty2> <x64|arm64>');
  }
  final package = arguments[0], architecture = arguments[1];
  serverPlatform(architecture);
  final root = Directory.fromUri(Platform.script).parent.parent.parent;
  await withBuildCancellation((cancellation) => buildNative(root, package, architecture, cancellation));
}

// Run each package's own build hook in isolation. Application Dart sources and
// their dependencies belong to the downstream AOT task, not this native build.
Future<void> buildNative(Directory root, String package, String architecture, CancellationToken cancellation) async {
  final source = await Directory.systemTemp.createTemp('happen-server-native-$package-');
  try {
    final spec = <String, Object?>{
      'name': 'happen_server_native_$package', 'publish_to': 'none',
      'environment': {'sdk': '>=3.13.0 <4.0.0'},
    };
    if (package == 'code_mode') {
      final original = loadYaml(await File('${root.path}/packages/code_mode/pubspec.yaml').readAsString()) as YamlMap;
      final dependencies = original['dependencies'] as YamlMap;
      spec['name'] = package;
      spec['dependencies'] = {for (final name in ['hooks', 'code_assets', 'native_toolchain_c']) name: dependencies[name]};
      for (final directory in ['native', 'native/quickjs', 'hook']) {
        await for (final entry in Directory('${root.path}/packages/code_mode/$directory').list()) {
          cancellation.throwIfCancelled();
          if (entry is! File) continue;
          final name = entry.uri.pathSegments.last;
          if (!(name.endsWith('.c') || name.endsWith('.h') || name == 'LICENSE' || directory == 'hook' && name == 'build.dart')) continue;
          final destination = File('${source.path}/$directory/$name');
          await destination.parent.create(recursive: true);
          await entry.copy(destination.path);
        }
      }
    } else {
      final lock = loadYaml(await File('${root.path}/pubspec.lock').readAsString()) as YamlMap;
      final locked = (lock['packages'] as YamlMap)[package] as YamlMap;
      if (locked['source'] != 'hosted') throw StateError('Expected a locked hosted native package: $package');
      final description = locked['description'] as YamlMap;
      spec['dependencies'] = {package: {'hosted': {'name': package, 'url': description['url']}, 'version': locked['version']}};
    }
    await File('${source.path}/pubspec.yaml').writeAsString('${jsonEncode(spec)}\n');
    final library = _libraries[package]!;
    final contract = linuxNativeContracts[library]!;
    // Retain this asset through Dart's tree shaking without calling its API.
    await File('${source.path}/main.dart').writeAsString("import 'dart:ffi';\n"
      "@Native<Void Function()>(assetId: ${jsonEncode(contract.assetId)}, symbol: ${jsonEncode(contract.anchor)})\n"
      'external void anchor();\n'
      'void main() { print(Native.addressOf<NativeFunction<Void Function()>>(anchor).address); }\n');
    final image = await buildServerImage(root, architecture, cancellation);
    await resolveServerPackages(image, root, source, architecture, cancellation);
    await runServerBuilder(image, source, architecture, ['build', 'cli', '--target=main.dart', '--output=/source/release'], cancellation);
    final libraries = (await Directory('${source.path}/release/bundle/lib').list().toList()).whereType<File>().toList();
    if (libraries.length != 1 || libraries.single.uri.pathSegments.last != library) {
      throw StateError('Expected only $library from $package, got ${libraries.map((file) => file.uri.pathSegments.last).toList()}');
    }
    final output = File('${root.path}/build/server/linux-$architecture/native/$library');
    await output.parent.create(recursive: true);
    await libraries.single.copy('${output.path}.pending');
    await File('${output.path}.pending').rename(output.path);
    stdout.writeln('Built ${output.path}');
  } finally { await source.delete(recursive: true); }
}
