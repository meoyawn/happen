import 'dart:convert';
import 'dart:io';

Map<String, Object?> _localSigningConfig() {
  final home = Platform.environment['HOME'];
  if (home == null) return {};
  final file = File('$home/.secrets/happen/config.json');
  if (!file.existsSync()) return {};
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) throw StateError('Invalid private Happen signing config');
  return decoded;
}

({String? identity, String? teamId, String? notaryKeyPath, String? notaryKeyId, String? notaryIssuerId})
    releaseCredentials() {
  final local = _localSigningConfig();
  final home = Platform.environment['HOME'];
  final localKey = home == null ? null : File('$home/.secrets/happen/notary.p8');
  String? setting(String environment, String localKey) =>
    Platform.environment[environment] ?? local[localKey] as String?;
  return (
    identity: setting('HAPPEN_CODESIGN_IDENTITY', 'appleSigningIdentity'),
    teamId: setting('HAPPEN_APPLE_TEAM_ID', 'appleTeamId'),
    notaryKeyPath: Platform.environment['HAPPEN_NOTARY_KEY_PATH'] ??
      ((localKey?.existsSync() ?? false) ? localKey!.path : null),
    notaryKeyId: setting('HAPPEN_NOTARY_KEY_ID', 'notaryKeyId'),
    notaryIssuerId: setting('HAPPEN_NOTARY_ISSUER_ID', 'notaryIssuerId'),
  );
}
