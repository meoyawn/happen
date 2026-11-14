import 'package:protocol/protocol.dart';

import 'src/quickjs.dart';

export 'src/quickjs.dart' show HostTool;
export 'src/cancellation.dart' show CodeInterrupt, CodeCancellationToken;
export 'src/output.dart' show truncateTextOutput, truncateTokenText;
export 'src/session.dart' show CodeSession;

/// Independent JavaScript cells with explicit persisted state and async host tools.
class CodeMode {
  const CodeMode({
    this.memoryLimit = 32 * 1024 * 1024,
  });
  final int memoryLimit;

  Future<Json> execute(
    String source, {
    required HostTool tool,
    required CancellationToken cancellation,
    Json values = const {},
    List<Json> catalog = const [],
    Duration? timeout,
    bool awaitPending = true,
  }) async {
    cancellation.throwIfCancelled();
    final engine = QuickJs(memoryLimit: memoryLimit);
    try {
      return await engine.run(
        source,
        tool: tool,
        cancellation: cancellation,
        values: values,
        catalog: catalog,
        timeout: timeout,
        awaitPending: awaitPending,
      );
    } finally {
      engine.close();
    }
  }
}
