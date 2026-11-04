import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('workspace analysis rejects unsafe async lifetimes and unchecked dynamic values', () async {
    final root = Directory.current;
    final fixture = await Directory.systemTemp.createTemp('analysis-contract-');
    addTearDown(() => fixture.delete(recursive: true));
    await File('${fixture.path}/pubspec.yaml').writeAsString("name: analysis_fixture\nenvironment:\n  sdk: '>=3.13.0 <4.0.0'\n");
    await File('${fixture.path}/analysis_options.yaml').writeAsString('include: ${root.path}/analysis_options.yaml\n');
    final original = File('${root.path}/.dart_tool/package_config.json');
    final packages = jsonObject(jsonDecode(await original.readAsString()));
    packages['packages'] = [for (final package in (packages['packages'] as List).map(jsonObject)) {
      ...package, 'rootUri': original.uri.resolve(package['rootUri'] as String).toString(),
    }];
    final config = File('${fixture.path}/.dart_tool/package_config.json');
    await config.parent.create();
    await config.writeAsString(jsonEncode(packages));
    final source = File('${fixture.path}/contract.dart');
    const safe = '''
import 'dart:async';

Future<int> safe(Future<int> work, void Function() cleanup) async {
  try { return await work; } finally { cleanup(); }
}
Future<int> caught(Future<int> work) async {
  try { return await work; } on Exception { return 0; }
}
Future<int> forwarding(Future<int> work) => work;
Future<int> nested(Future<int> work, void Function() cleanup) async {
  try {
    Future<int> forward() async { return work; }
    return await forward();
  } finally { cleanup(); }
}
Future<void> background(Future<void> work) async { unawaited(work); }
''';
    await source.writeAsString(safe);
    Future<({int exitCode, List<String> diagnostics})> analyze() async {
      final token = TimeoutCancellationToken(const Duration(minutes: 2));
      final process = await Process.start(Platform.resolvedExecutable, ['analyze', '--format=machine', source.path], workingDirectory: fixture.path);
      final hook = CancellationHook(token, () => process.kill(ProcessSignal.sigterm));
      try {
        final output = utf8.decoder.bind(process.stdout).join();
        final errors = utf8.decoder.bind(process.stderr).join();
        final code = await process.exitCode.asCancellable(token);
        final text = '${await output}\n${await errors}';
        return (exitCode: code, diagnostics: const LineSplitter().convert(text).where((line) => line.contains('|')).toList());
      } finally { hook.dispose(); token.cancel(); }
    }
    final passing = await analyze();
    expect(passing.exitCode, 0, reason: passing.diagnostics.join('\n'));
    await source.writeAsString('''$safe
Future<int> prematureCleanup(Future<int> work, void Function() cleanup) async {
  try { return work; } finally { cleanup(); }
}
Future<int> bypassedCatch(Future<int> work) async {
  try { return work; } on Exception { return 0; }
}
Future<int> futureOrCleanup(FutureOr<int> work, void Function() cleanup) async {
  try { return work; } finally { cleanup(); }
}
Future<void> lostAsync(Future<void> Function() work) async { work(); }
void lostSync(Future<void> Function() work) { work(); }
String unchecked(dynamic value) => value;
''');
    final failing = await analyze();
    expect(failing.exitCode, isNot(0));
    final codes = failing.diagnostics.map((line) => line.split('|')[2].toLowerCase()).toList();
    expect(codes.where((code) => code.endsWith('await_before_cleanup')), hasLength(3), reason: failing.diagnostics.join('\n'));
    expect(failing.diagnostics.where((line) => line.toLowerCase().contains('await_before_cleanup')),
      everyElement(startsWith('ERROR|')));
    expect(codes, containsAll(['unawaited_futures', 'discarded_futures', 'return_of_invalid_type']));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
