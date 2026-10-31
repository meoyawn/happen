import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _sources = [
  'native/bridge.c',
  'native/quickjs/quickjs.c',
  'native/quickjs/libregexp.c',
  'native/quickjs/libunicode.c',
  'native/quickjs/cutils.c',
  'native/quickjs/dtoa.c',
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS == OS.windows) {
      await _windows(input, output);
      return;
    }
    await CBuilder.library(
      name: 'code_mode',
      assetName: 'src/bindings.dart',
      sources: _sources,
      includes: ['native/quickjs'],
      defines: {'_GNU_SOURCE': null, 'CONFIG_VERSION': '"2026-06-04"'},
      flags: ['-std=gnu11'],
      libraries: ['m', 'pthread'],
    ).run(input: input, output: output);
  });
}

Future<void> _windows(BuildInput input, BuildOutputBuilder output) async {
  if (input.config.code.targetArchitecture != Architecture.x64) {
    throw UnsupportedError('The Windows QuickJS build currently supports x64');
  }
  // Upstream QuickJS uses GNU C and winpthreads on Windows; MSVC cannot build it.
  final compiler = input.userDefines['mingw_cc'] as String? ?? r'C:\msys64\ucrt64\bin\gcc.exe';
  final target = await Process.run(compiler, ['-dumpmachine']);
  if (target.exitCode != 0 || !target.stdout.toString().trim().startsWith('x86_64-') ||
      !target.stdout.toString().contains('mingw')) {
    throw StateError('Configure hooks.user_defines.code_mode.mingw_cc with an x64 MinGW-w64 GCC');
  }
  final library = input.outputDirectory.resolve('code_mode.dll');
  await Directory.fromUri(input.outputDirectory).create(recursive: true);
  final sources = [for (final source in _sources) input.packageRoot.resolve(source)];
  final exports = input.packageRoot.resolve('native/windows.def');
  final includes = input.packageRoot.resolve('native/quickjs/');
  final result = await Process.run(compiler, [
    '-shared', '-O3', '-std=gnu11', '-fwrapv',
    '-D_GNU_SOURCE', '-D__USE_MINGW_ANSI_STDIO', '-DCONFIG_VERSION="2026-06-04"',
    '-I${includes.toFilePath()}',
    for (final source in sources) source.toFilePath(),
    exports.toFilePath(), '-Wl,--exclude-all-symbols',
    '-o', library.toFilePath(),
    // Keep GCC and winpthreads in this DLL; deployment needs no MinGW DLLs.
    '-static', '-lm', '-lpthread',
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(compiler, const [], result.stderr.toString(), result.exitCode);
  }
  output.assets.code.add(CodeAsset(
    package: input.packageName,
    name: 'src/bindings.dart',
    file: library,
    linkMode: DynamicLoadingBundled(),
  ));
  output.dependencies.addAll([
    ...sources, exports, File(compiler).absolute.uri,
    await for (final entry in Directory.fromUri(includes).list())
      if (entry is File && entry.path.endsWith('.h')) entry.uri,
  ]);
}
