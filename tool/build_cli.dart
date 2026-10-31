import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

import 'cli_native_bootstrap.dart' show cliNativeContracts;

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) throw ArgumentError('This target takes no arguments');
  if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
    throw UnsupportedError('The single-file CLI release currently targets macOS arm64');
  }
  final root = File.fromUri(Platform.script).absolute.parent.parent;
  final pin = jsonObject(jsonDecode(await File('${root.path}/tool/dart2native.json').readAsString()));
  final version = Platform.version.split(' ').first;
  if (version != pin['sdk_version']) throw StateError('This builder requires Dart ${pin['sdk_version']} and its matching Mach-O writer');
  final sdk = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
  final sdkRoot = File(sdk).parent.parent.path;
  final cache = Directory('${root.path}/.local/build-cli')..createSync(recursive: true);
  final output = Directory('${root.path}/build/cli')..createSync(recursive: true);
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  final lock = await File('${cache.path}/build.lock').open(mode: FileMode.append);
  final cancelLock = CancellationHook(cancellation, () => unawaited(lock.close().catchError((Object _) {})));
  var locked = false;
  try {
    await lock.lock(FileLock.blockingExclusive);
    locked = true;
    cancelLock.dispose();
    cancellation.throwIfCancelled();
    final sources = await _compilerSources(cache, pin, cancellation);
    stdout.writeln('Building the CLI and its native assets with the package build hooks.');
    await _run(sdk, ['build', 'cli', '--target=bin/happen.dart', '--output=${cache.path}/native'], root.path, cancellation);
    final native = Directory('${cache.path}/native/bundle/lib');
    final libraries = (await native.list().toList()).whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
    final actual = libraries.map((file) => file.uri.pathSegments.last).toSet();
    if (actual.length != cliNativeContracts.length || !actual.containsAll(cliNativeContracts.keys)) {
      throw StateError('Native assets changed; update the explicit CLI binding contracts: $actual');
    }
    final manifest = <Json>[];
    for (final file in libraries) {
      final name = file.uri.pathSegments.last;
      final result = await _run('/usr/bin/otool', ['-D', file.path], root.path, cancellation, capture: true);
      final installName = result.trim().split('\n').last.trim();
      if (!installName.startsWith('@rpath/') || !installName.endsWith('/$name')) throw StateError('Unexpected dylib install name: $name');
      final bytes = await file.readAsBytes();
      manifest.add({'name': name, 'asset_id': cliNativeContracts[name]!.assetId,
        'install_name': installName, 'length': bytes.length, 'sha256': sha256.convert(bytes).toString()});
    }
    final nativeId = sha256.convert(utf8.encode(jsonEncode(manifest))).toString();
    final work = await cache.createTemp('release-');
    try {
      final bootstrap = File('${root.path}/tool/cli_native_bootstrap.dart').uri;
      final payload = File('${work.path}/payload.dart').openWrite();
      payload.writeln("import '$bootstrap';\nconst nativeId = '$nativeId';\nconst assets = <EmbeddedNativeAsset>[");
      for (var i = 0; i < manifest.length; i++) {
        final asset = manifest[i];
        payload.writeln('  (name: ${jsonEncode(asset['name'])}, sha256: ${jsonEncode(asset['sha256'])}, length: ${asset['length']}, payload: _payload$i),');
      }
      payload.writeln('];');
      var compressedBytes = 0;
      for (var i = 0; i < libraries.length; i++) {
        final compressed = GZipCodec(level: 6).encode(await libraries[i].readAsBytes());
        compressedBytes += compressed.length;
        final encoded = base64.encode(compressed);
        payload.writeln('String _payload$i() =>');
        for (var offset = 0; offset < encoded.length; offset += 4096) {
          payload.writeln('  ${jsonEncode(encoded.substring(offset, (offset + 4096).clamp(0, encoded.length)))}');
        }
        payload.writeln(';');
      }
      await payload.close();
      final main = File('${work.path}/main.dart');
      await main.writeAsString("import '${File('${root.path}/bin/happen.dart').uri}' as cli;\nimport '$bootstrap';\nimport 'payload.dart';\nFuture<void> main(List<String> arguments) async {\n  await bootstrapNativeAssets(nativeId, assets);\n  await cli.main(arguments);\n}\n");
      final assets = File('${work.path}/native_assets.json');
      await assets.writeAsString(jsonEncode({'format-version': [1, 0, 0], 'native-assets': {
        'macos_arm64': {for (final asset in manifest) asset['asset_id']: ['system', asset['install_name']]},
      }}));
      stdout.writeln('Compiling happen with its embedded native payload.');
      final kernel = '${work.path}/program.dill', snapshot = '${work.path}/snapshot.aot';
      await _run('$sdkRoot/bin/dartaotruntime', [
        '$sdkRoot/bin/snapshots/gen_kernel_aot.dart.snapshot',
        '--platform=$sdkRoot/lib/_internal/vm_platform_product.dill',
        '-Ddart.vm.product=true', '--target-os=macos', '--aot', '--no-embed-sources',
        '--packages=${root.path}/.dart_tool/package_config.json', '--native-assets=${assets.path}', '--output=$kernel', main.path,
      ], root.path, cancellation);
      await _run('$sdkRoot/bin/utils/gen_snapshot', ['--snapshot-kind=app-aot-elf', '--elf=$snapshot', '--strip', kernel], root.path, cancellation);
      final writer = File('${work.path}/write_executable.dart');
      await writer.writeAsString("import '${File('${sources.path}/pkg/dart2native/lib/dart2native_macho.dart').uri}';\nFuture<void> main(List<String> args) => writeAppendedMachOExecutable(args[0], args[1], args[2]);\n");
      final candidate = File('${work.path}/happen');
      await _run(sdk, [writer.path, '$sdkRoot/bin/dartaotruntime', snapshot, candidate.path], root.path, cancellation);
      await _run('/bin/chmod', ['755', candidate.path], root.path, cancellation);
      await _run('/usr/bin/codesign', ['--verify', '--strict', candidate.path], root.path, cancellation);
      final dependencies = await _run('/usr/bin/otool', ['-L', candidate.path], root.path, cancellation, capture: true);
      for (final line in const LineSplitter().convert(dependencies).skip(1)) {
        final library = line.trim().split(' (').first;
        if (!library.startsWith('/usr/lib/') && !library.startsWith('/System/Library/')) {
          throw StateError('CLI has a non-system dylib dependency: $library');
        }
      }
      final pending = await candidate.copy('${output.path}/happen.pending');
      await pending.rename('${output.path}/happen');
      await File('${output.path}/build-report.json').writeAsString('${const JsonEncoder.withIndent('  ').convert({
        'target': 'macos-arm64', 'dart_sdk': version, 'native_id': nativeId, 'native_assets': manifest,
        'compressed_native_bytes': compressedBytes, 'executable_bytes': await candidate.length(),
        'sha256': sha256.convert(await candidate.readAsBytes()).toString(),
        'signing': 'ad-hoc', 'sdk_source_pin': pin,
      })}\n');
      stdout.writeln('Built ${output.path}/happen.');
    } finally { await work.delete(recursive: true); }
  } finally {
    cancelLock.dispose();
    if (locked) await lock.unlock();
    try { await lock.close(); } catch (_) { /* Cancellation can close a waiting lock. */ }
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<Directory> _compilerSources(Directory cache, Json pin, CancellationToken cancellation) async {
  final directory = Directory('${cache.path}/dart-sdk-${pin['revision']}');
  final http = HttpClient();
  final hook = CancellationHook(cancellation, () => http.close(force: true));
  try {
    for (final entry in jsonObject(pin['files']).entries) {
      cancellation.throwIfCancelled();
      final file = File('${directory.path}/${entry.key}');
      if (await file.exists() && sha256.convert(await file.readAsBytes()).toString() == entry.value) continue;
      final uri = Uri.parse('https://raw.githubusercontent.com/dart-lang/sdk/${pin['revision']}/${entry.key}');
      final response = await (await http.getUrl(uri).asCancellable(cancellation)).close().asCancellable(cancellation);
      if (response.statusCode != 200) throw StateError('Unable to fetch the pinned Dart executable writer');
      final bytes = <int>[];
      await for (final chunk in response) {
        cancellation.throwIfCancelled();
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) throw StateError('Pinned Dart source exceeds its size bound');
      }
      if (sha256.convert(bytes).toString() != entry.value) throw StateError('Pinned Dart source checksum mismatch: ${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    }
    return directory;
  } finally { hook.dispose(); http.close(force: true); }
}

Future<String> _run(String command, List<String> arguments, String cwd, CancellationToken cancellation, {bool capture = false}) async {
  cancellation.throwIfCancelled();
  final process = await Process.start(command, arguments, workingDirectory: cwd);
  final hook = CancellationHook(cancellation, () => process.kill());
  try {
    final output = StringBuffer();
    await Future.wait([
      process.stdout.forEach((bytes) { if (capture) { output.write(utf8.decode(bytes)); } else { stdout.add(bytes); } }),
      process.stderr.forEach(stderr.add),
    ]);
    final code = await process.exitCode;
    cancellation.throwIfCancelled();
    if (code != 0) throw ProcessException(command, arguments, 'CLI build step failed', code);
    return output.toString();
  } finally { hook.dispose(); }
}
