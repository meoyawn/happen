import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';

import '../test/fixtures/context_contract/environment.dart';

// Isolate the test process itself, not only the independent Codex child. Real
// in-process Happen shell/MCP children must not read the caller's startup files,
// package credentials, configuration, or global skills.
Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) throw ArgumentError('The E2E matrix is fixed; run moon run test-e2e without overrides');
  final home = await Directory.systemTemp.createTemp('happen-context-contract-');
  final output = '${Platform.environment['HAPPEN_TEST_REPORT_ROOT'] ?? Directory.current.path}/.local/context-contract/${DateTime.now().microsecondsSinceEpoch}';
  final repository = Platform.environment['HAPPEN_TEST_REPORT_ROOT'] ?? Directory.current.path;
  final codexSource = Directory(Platform.environment['CODEX_SOURCE_DIR'] ?? '$repository/../github/codex').absolute.path;
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  Process? process;
  CancellationHook? hook;
  try {
    final packages = (await Isolate.packageConfig)!;
    final testLibrary = (await Isolate.resolvePackageUri(Uri.parse('package:test/test.dart')))!;
    // The outer dart run builds native hooks. Invoke the source test runner
    // directly: dart test under a different PUB_CACHE would re-resolve and
    // rewrite this workspace's package_config.json with temporary paths.
    process = await Process.start(Platform.resolvedExecutable, [
      '--disable-dart-dev', '--packages=${packages.toFilePath()}',
      testLibrary.resolve('../bin/test.dart').toFilePath(), 'test/contracts/codex_context_test.dart',
    ],
      mode: ProcessStartMode.inheritStdio, includeParentEnvironment: false,
      environment: {...isolatedEnvironment(home.path, '${home.path}/.codex'), 'CONTEXT_CONTRACT_HOME': home.path,
        if (Platform.environment['DART_MCP_SERVER_EXECUTABLE'] case final String executable)
          'DART_MCP_SERVER_EXECUTABLE': executable,
        'CONTEXT_CONTRACT_CODEX_SOURCE': codexSource,
        'CONTEXT_CONTRACT_OUTPUT': output});
    hook = CancellationHook(cancellation, () => process?.kill(ProcessSignal.sigterm));
    exitCode = await process.exitCode.asCancellable(cancellation);
  } on CancelledException {
    exitCode = 130;
  } finally {
    hook?.dispose();
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try { await process.exitCode.timeout(const Duration(seconds: 5)); }
      on TimeoutException { process.kill(ProcessSignal.sigkill); await process.exitCode; }
    }
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
    await home.delete(recursive: true);
  }
}
