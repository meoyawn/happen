import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await CBuilder.library(
      name: 'code_mode',
      assetName: 'src/bindings.dart',
      sources: [
        'native/bridge.c',
        'native/quickjs/quickjs.c',
        'native/quickjs/libregexp.c',
        'native/quickjs/libunicode.c',
        'native/quickjs/cutils.c',
        'native/quickjs/dtoa.c',
      ],
      includes: ['native/quickjs'],
      defines: {'_GNU_SOURCE': null, 'CONFIG_VERSION': '"2026-06-04"'},
      flags: ['-std=gnu11'],
      libraries: ['m', 'pthread'],
    ).run(input: input, output: output);
  });
}
