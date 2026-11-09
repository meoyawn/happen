import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

import '../cli_native_bootstrap.dart' show linuxNativeContracts;

// Runs inside the Linux build environment after the normal native build hooks.
// The same extraction and anchor checks serve the macOS CLI and Linux daemon.
Future<void> main(List<String> arguments) async {
  if (!Platform.isLinux || arguments.length != 2) throw ArgumentError('Provide the native bundle and output executable on Linux');
  final bundle = Directory(arguments[0]).absolute, output = File(arguments[1]).absolute;
  final root = Directory.fromUri(Platform.script).parent.parent.parent;
  final sdk = File(await File(Platform.resolvedExecutable).resolveSymbolicLinks()).parent.parent;
  final libraries = (await Directory('${bundle.path}/lib').list().toList()).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final names = libraries.map((file) => file.uri.pathSegments.last).toSet();
  if (names.length != linuxNativeContracts.length || !names.containsAll(linuxNativeContracts.keys)) {
    throw StateError('Native assets changed; update the explicit Linux binding contracts: $names');
  }
  final assets = <Json>[];
  for (final library in libraries) {
    final name = library.uri.pathSegments.last, bytes = await library.readAsBytes();
    assets.add({'name': name, 'asset_id': linuxNativeContracts[name]!.assetId,
      'length': bytes.length, 'sha256': sha256.convert(bytes).toString()});
  }
  final nativeId = sha256.convert(utf8.encode(jsonEncode(assets))).toString();
  final work = await Directory('${root.path}/release').createTemp('embed-');
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  try {
    final bootstrap = File('${root.path}/tool/cli_native_bootstrap.dart').uri;
    final payload = File('${work.path}/payload.dart').openWrite();
    payload.writeln("import '$bootstrap';\nconst nativeId = '$nativeId';\nconst assets = <EmbeddedNativeAsset>[");
    for (var i = 0; i < assets.length; i++) {
      final asset = assets[i];
      payload.writeln('  (name: ${jsonEncode(asset['name'])}, sha256: ${jsonEncode(asset['sha256'])}, length: ${asset['length']}, payload: _payload$i),');
    }
    payload.writeln('];');
    for (var i = 0; i < libraries.length; i++) {
      final compressed = base64.encode(GZipCodec(level: 6).encode(await libraries[i].readAsBytes()));
      payload.writeln('String _payload$i() =>');
      for (var offset = 0; offset < compressed.length; offset += 4096) {
        payload.writeln('  ${jsonEncode(compressed.substring(offset, (offset + 4096).clamp(0, compressed.length)))}');
      }
      payload.writeln(';');
    }
    await payload.close();
    final main = File('${work.path}/main.dart');
    await main.writeAsString("import '${File('${root.path}/packages/server/bin/happen_server.dart').uri}' as server;\n"
      "import '$bootstrap';\nimport 'payload.dart';\nFuture<void> main(List<String> arguments) async {\n"
      "  await bootstrapNativeAssets(nativeId, assets);\n  await server.main(arguments);\n}\n");
    final target = switch (Abi.current()) { Abi.linuxX64 => 'linux_x64', Abi.linuxArm64 => 'linux_arm64', _ => throw UnsupportedError('Unsupported Linux ABI') };
    final manifest = File('${work.path}/native-assets.json');
    await manifest.writeAsString(jsonEncode({'format-version': [1, 0, 0], 'native-assets': {
      target: {for (final asset in assets) asset['asset_id']: ['process']},
    }}));
    final kernel = '${work.path}/program.dill', snapshot = '${work.path}/snapshot.aot';
    await _run('${sdk.path}/bin/dartaotruntime', [
      '${sdk.path}/bin/snapshots/gen_kernel_aot.dart.snapshot',
      '--platform=${sdk.path}/lib/_internal/vm_platform_product.dill', '-Ddart.vm.product=true',
      '--target-os=linux', '--aot', '--no-embed-sources', '--packages=${root.path}/.dart_tool/package_config.json',
      '--native-assets=${manifest.path}', '--output=$kernel', main.path,
    ], cancellation);
    await _run('${sdk.path}/bin/utils/gen_snapshot', ['--snapshot-kind=app-aot-elf', '--elf=$snapshot', '--strip', kernel], cancellation);
    // Stock Dart ELF trailer format, from SDK pkg/dart2native/lib/dart2native.dart:
    // a 64 KiB aligned snapshot, its little-endian offset, and the VM magic.
    final runtime = await File('${sdk.path}/bin/dartaotruntime').readAsBytes();
    final aligned = (runtime.length + 65535) & ~65535;
    final offset = ByteData(8)..setUint64(0, aligned, Endian.little);
    final executable = BytesBuilder(copy: false)
      ..add(runtime)..add(Uint8List(aligned - runtime.length))..add(await File(snapshot).readAsBytes())
      ..add(offset.buffer.asUint8List())..add([0xdc, 0xdc, 0xf6, 0xf6, 0, 0, 0, 0]);
    await output.writeAsBytes(executable.takeBytes(), flush: true);
    await _run('chmod', ['755', output.path], cancellation);
    final cache = await work.createTemp('native-smoke-');
    for (var launch = 0; launch < 2; launch++) {
      await _run(output.path, ['--version'], cancellation,
        environment: {'HAPPEN_NATIVE_CACHE': cache.path, 'HAPPEN_BOOTSTRAP_REPORT': '1'});
    }
    await File('${output.path}.native.json').writeAsString('${jsonEncode({'nativeId': nativeId, 'nativeAssets': assets})}\n');
  } finally {
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
    await work.delete(recursive: true);
  }
}

Future<void> _run(String executable, List<String> arguments, CancellationToken cancellation, {Map<String, String>? environment}) async {
  cancellation.throwIfCancelled();
  final process = await Process.start(executable, arguments, environment: environment);
  final hook = CancellationHook(cancellation, () => process.kill());
  try {
    await process.stdin.close();
    await Future.wait([process.stdout.forEach(stdout.add), process.stderr.forEach(stderr.add)]);
    final code = await process.exitCode;
    cancellation.throwIfCancelled();
    if (code != 0) throw StateError('Linux embedding step failed: $executable ($code)');
  } finally { hook.dispose(); }
}
