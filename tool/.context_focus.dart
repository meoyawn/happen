import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final packageConfig = File('.dart_tool/package_config.json').absolute;
  final packages = jsonDecode(await packageConfig.readAsString()) as Map;
  final test = (packages['packages'] as List).cast<Map>().singleWhere((entry) => entry['name'] == 'test');
  final testBin = packageConfig.uri.resolve('${test['rootUri']}/').resolve('bin/test.dart');
  final home = await Directory.systemTemp.createTemp('happen-contract-focus-');
  final output = '${Platform.environment['HAPPEN_TEST_REPORT_ROOT'] ?? Directory.current.path}/.local/context-contract/focus-${DateTime.now().microsecondsSinceEpoch}';
  Process? child;
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => child?.kill(ProcessSignal.sigterm))).toList();
  try {
    child = await Process.start(Platform.resolvedExecutable, [
      '--disable-dart-dev', '--packages=${packageConfig.path}', testBin.toFilePath(),
      'test/contracts/codex_context_test.dart', '-r', 'expanded', '--name', arguments.single,
    ], environment: {
      for (final key in ['PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'TZ'])
        if (Platform.environment[key] case final String value) key: value,
      'HOME': home.path, 'USERPROFILE': home.path,
      'PUB_CACHE': '${home.path}/.pub-cache', 'CODEX_HOME': '${home.path}/.codex',
      'CONTEXT_CONTRACT_HOME': home.path, 'CONTEXT_CONTRACT_OUTPUT': output,
    }, includeParentEnvironment: false, mode: ProcessStartMode.inheritStdio);
    exitCode = await child.exitCode;
  } finally {
    child?.kill(ProcessSignal.sigterm);
    for (final signal in signals) { await signal.cancel(); }
    await home.delete(recursive: true);
  }
}
