// Modified from Codex 6abffd442d68 (Apache-2.0), codex-mcp/src/
// rmcp_client.rs, connection_manager.rs and pagination.rs, and
// rmcp-client/src/rmcp_client.rs. See packages/openai/tools/CODEX-NOTICE.
import 'dart:async';

const mcpStartupTimeout = Duration(seconds: 30);
const mcpToolTimeout = Duration(seconds: 300);
const mcpCatalogTimeout = Duration(seconds: 30);

// A caller may shorten a configured tool budget, never extend it. Happen's
// config has no timeout overrides, so the server budget is the Codex default.
Duration mcpRequestedToolTimeout(Duration? requested) =>
  requested == null || requested > mcpToolTimeout ? mcpToolTimeout : requested;

TimeoutException mcpOperationTimeout(String method, Duration duration) {
  // Rust's Duration debug formatter with zero precision chooses a unit before
  // rounding. Dart durations have microsecond precision.
  final micros = duration.inMicroseconds;
  final rounded = micros >= Duration.microsecondsPerSecond
    ? '${(micros / Duration.microsecondsPerSecond).round()}s'
    : micros >= Duration.microsecondsPerMillisecond
      ? '${(micros / Duration.microsecondsPerMillisecond).round()}ms' : '$microsµs';
  return TimeoutException('timed out awaiting $method after $rounded', duration);
}
