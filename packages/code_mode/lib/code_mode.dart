import 'package:protocol/protocol.dart';

import 'src/quickjs.dart';

export 'src/quickjs.dart' show HostTool;
export 'src/output.dart' show truncateTextOutput;

/// Independent JavaScript cells with explicit persisted state and async host tools.
class CodeMode {
  const CodeMode({
    this.memoryLimit = 32 * 1024 * 1024,
    this.cpuBudgetMs = 1000,
  });
  final int memoryLimit, cpuBudgetMs;

  Future<Json> execute(
    String source, {
    required HostTool tool,
    required CancellationToken cancellation,
    Json values = const {},
    List<Json> catalog = const [],
    Duration timeout = const Duration(seconds: 60),
    bool awaitPending = true,
  }) async {
    final engine = QuickJs(memoryLimit: memoryLimit);
    try {
      return await engine.run(
        source,
        tool: tool,
        cancellation: cancellation,
        values: values,
        catalog: catalog,
        timeout: timeout,
        cpuBudgetMs: cpuBudgetMs,
        awaitPending: awaitPending,
      );
    } finally {
      engine.close();
    }
  }
}
