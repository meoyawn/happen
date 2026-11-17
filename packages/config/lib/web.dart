import 'dart:io';
import 'package:cancellation_token/cancellation_token.dart';
import 'config.dart';

typedef WebConfiguration = ({String? publicUrl, String ownerKeyFile,
  int port, Set<String> allowedOrigins, String tunnelTokenFile});

/// Only paths to owner and connector credentials belong in configuration.
/// Credential values are read by their effect owner and never enter the schema.
Future<WebConfiguration> loadWebConfiguration({String? path, required CancellationToken cancellation}) async {
  final config = await loadConfig(path ?? defaultConfigPath(), cancellation: cancellation);
  final web = config.values['web'] as Map? ?? const {}, tunnel = config.values['tunnel'] as Map? ?? const {};
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']!;
  String expand(String value) => value.startsWith('~/') ? '$home/${value.substring(2)}' : value;
  return (publicUrl: web['public_url'] as String?,
    ownerKeyFile: expand(web['owner_key_file'] as String? ?? '~/.secrets/happen/owner-key'),
    port: web['port'] as int? ?? 8787,
    allowedOrigins: (web['allowed_origins'] as List? ?? const []).cast<String>().toSet(),
    tunnelTokenFile: expand(tunnel['token_file'] as String? ?? '~/.secrets/happen/tunnel-token'));
}
