import 'dart:convert';
import 'dart:io';
import 'dart:math';

void main(List<String> arguments) {
  if (!Platform.isMacOS || arguments.length != 1 || !['setup', 'cleanup'].contains(arguments.single)) {
    throw StateError('Usage: ci_signing.dart setup|cleanup on macOS');
  }
  final temp = Platform.environment['RUNNER_TEMP'];
  if (temp == null || temp.isEmpty) throw StateError('RUNNER_TEMP is required');
  final directory = Directory('$temp/happen-signing');
  if (arguments.single == 'cleanup') {
    _cleanup(directory);
  } else {
    _setup(directory);
  }
}

void _setup(Directory directory) {
  String required(String name) {
    final value = Platform.environment[name];
    if (value == null || value.isEmpty) throw StateError('Missing $name Actions secret');
    return value;
  }
  final identity = required('MACOS_SIGNING_IDENTITY');
  final team = required('MACOS_TEAM_ID');
  if (!identity.startsWith('Developer ID Application: ') || !identity.endsWith(' ($team)')) {
    throw StateError('Developer ID signing identity and team do not match');
  }
  if (directory.existsSync()) throw StateError('Stale CI signing directory exists');
  _run('Create private signing directory', '/bin/mkdir', ['-m', '700', directory.path]);
  final keychain = '${directory.path}/release.keychain-db';
  final certificate = File('${directory.path}/certificate.p12');
  final notaryKey = File('${directory.path}/notary.p8');
  final previous = RegExp(r'"([^"]+)"').allMatches(_run('Read keychain search list',
    '/usr/bin/security', ['list-keychains', '-d', 'user'])).map((match) => match.group(1)!).toList();
  File('${directory.path}/keychains.json').writeAsStringSync(jsonEncode(previous));
  certificate.writeAsBytesSync(base64Decode(required('MACOS_CERTIFICATE_P12_BASE64')));
  notaryKey.writeAsBytesSync(base64Decode(required('MACOS_NOTARY_KEY_P8_BASE64')));
  _run('Protect signing files', '/bin/chmod', ['600', certificate.path, notaryKey.path]);
  final random = Random.secure();
  final password = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
  _run('Create signing keychain', '/usr/bin/security', ['create-keychain', '-p', password, keychain]);
  _run('Configure signing keychain', '/usr/bin/security', ['set-keychain-settings', '-lut', '21600', keychain]);
  _run('Unlock signing keychain', '/usr/bin/security', ['unlock-keychain', '-p', password, keychain]);
  _run('Import Developer ID certificate', '/usr/bin/security', ['import', certificate.path,
    '-k', keychain, '-P', required('MACOS_CERTIFICATE_PASSWORD'), '-T', '/usr/bin/codesign', '-T', '/usr/bin/security']);
  _run('Allow unattended code signing', '/usr/bin/security', ['set-key-partition-list',
    '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain]);
  _run('Select signing keychain', '/usr/bin/security', ['list-keychains', '-d', 'user', '-s', keychain, ...previous]);
  final available = _run('Verify imported identity', '/usr/bin/security', ['find-identity', '-v', '-p', 'codesigning', keychain]);
  if (!available.contains('"$identity"')) throw StateError('Developer ID identity missing from imported keychain');
  final githubEnv = Platform.environment['GITHUB_ENV'];
  if (githubEnv == null || githubEnv.isEmpty) throw StateError('GITHUB_ENV is required');
  final environment = [
    'HAPPEN_CODESIGN_IDENTITY=$identity',
    'HAPPEN_APPLE_TEAM_ID=$team',
    'HAPPEN_NOTARY_KEY_PATH=${notaryKey.path}',
    'HAPPEN_NOTARY_KEY_ID=${required('MACOS_NOTARY_KEY_ID')}',
    'HAPPEN_NOTARY_ISSUER_ID=${required('MACOS_NOTARY_ISSUER_ID')}',
    'HAPPEN_REQUIRE_DEVELOPER_ID=1',
  ].join('\n');
  File(githubEnv).writeAsStringSync('$environment\n', mode: FileMode.append);
  stdout.writeln('Imported Developer ID signing credentials into an ephemeral keychain.');
}

void _cleanup(Directory directory) {
  final previous = File('${directory.path}/keychains.json');
  if (previous.existsSync()) {
    final names = (jsonDecode(previous.readAsStringSync()) as List).cast<String>();
    _run('Restore keychain search list', '/usr/bin/security', ['list-keychains', '-d', 'user', '-s', ...names]);
  }
  final keychain = File('${directory.path}/release.keychain-db');
  if (keychain.existsSync()) _run('Delete signing keychain', '/usr/bin/security', ['delete-keychain', keychain.path]);
  if (directory.existsSync()) directory.deleteSync(recursive: true);
  stdout.writeln('Removed ephemeral signing credentials.');
}

String _run(String step, String command, List<String> arguments) {
  final result = Process.runSync(command, arguments);
  if (result.exitCode != 0) throw StateError('$step failed: ${result.stderr}');
  return result.stdout as String;
}
