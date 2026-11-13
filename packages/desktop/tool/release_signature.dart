import 'dart:io';

void verifyReleaseSignature(Directory bundle, {bool requireDeveloperId = false, String? expectedTeamId}) {
  final verification = Process.runSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle.path]);
  if (verification.exitCode != 0) {
    throw StateError('Invalid release code signature: ${verification.stderr}');
  }
  final display = Process.runSync('/usr/bin/codesign', ['-dv', '--verbose=4', bundle.path]);
  if (display.exitCode != 0) throw StateError('Could not inspect release code signature: ${display.stderr}');
  final metadata = display.stderr as String;
  if (!RegExp(r'^Identifier=com\.adelnz\.happen$', multiLine: true).hasMatch(metadata) ||
      !RegExp(r'^TeamIdentifier=[A-Z0-9]{10}$', multiLine: true).hasMatch(metadata) ||
      metadata.contains('Signature=adhoc') ||
      expectedTeamId != null && !metadata.contains('TeamIdentifier=$expectedTeamId')) {
    throw StateError('Release app must have a stable Apple-signed Happen identity');
  }
  if (requireDeveloperId && (!RegExp(r'^Authority=Developer ID Application: ', multiLine: true).hasMatch(metadata) ||
      !RegExp(r'^CodeDirectory .*flags=.*\bruntime\b', multiLine: true).hasMatch(metadata) ||
      !RegExp(r'^Timestamp=', multiLine: true).hasMatch(metadata))) {
    throw StateError('Public release requires Developer ID signing, hardened runtime, and a secure timestamp');
  }
  if (requireDeveloperId) {
    final entitlements = Process.runSync('/usr/bin/codesign', ['-d', '--entitlements', '-', bundle.path]);
    final actual = '${entitlements.stdout}\n${entitlements.stderr}';
    if (entitlements.exitCode != 0 || actual.contains('com.apple.security.get-task-allow') ||
        !actual.contains('com.apple.security.device.audio-input')) {
      throw StateError('Public release has invalid microphone or debugging entitlements');
    }
  }
  final requirement = Process.runSync('/usr/bin/codesign', ['-d', '-r-', bundle.path]);
  final designated = '${requirement.stdout}\n${requirement.stderr}';
  if (requirement.exitCode != 0 || !designated.contains('designated =>') ||
      !designated.contains('identifier "com.adelnz.happen"') || designated.contains('cdhash')) {
    throw StateError('Release designated requirement must survive app updates');
  }
}
