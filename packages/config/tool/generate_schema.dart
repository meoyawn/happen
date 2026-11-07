import 'dart:convert';
import 'dart:io';

void main() {
  final source = File.fromUri(Platform.script.resolve('../schema.json'));
  final schema = const JsonEncoder.withIndent('  ').convert(jsonDecode(source.readAsStringSync()));
  File.fromUri(Platform.script.resolve('../lib/src/schema.dart')).writeAsStringSync(
    '// Generated from packages/config/schema.json.\n'
    '// Run: dart packages/config/tool/generate_schema.dart\n'
    'const globalConfigSchema = <String, Object?>${schema.replaceAll(r'$', r'\$')};\n');
}
