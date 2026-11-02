import 'package:ai/ai.dart';
import 'package:test/test.dart';

void main() {
  test('tool inputs enforce composed schemas without coercion or implicit bounds', () {
    final cases = <(Map<String, dynamic>, Object?, Object?)>[
      ({'type': 'integer'}, -1, '1'),
      ({'anyOf': [{'type': 'null'}, {'type': 'string', 'pattern': r'^ok$'}]}, null, 'wrong'),
      ({
        'type': 'array', 'minItems': 1,
        'items': {r'$ref': r'#/$defs/id'},
        r'$defs': {'id': {'type': 'string', 'pattern': r'^[a-z]+$'}},
      }, ['valid'], []),
    ];
    for (final (schema, valid, invalid) in cases) {
      expect(() => validateToolInput(valid, schema, 'probe'), returnsNormally);
      expect(() => validateToolInput(invalid, schema, 'probe'), throwsFormatException);
    }
  });

  test('tool input diagnostics locate referenced array fields without echoing values', () {
    const schema = <String, dynamic>{
      'type': 'object',
      'properties': {'rows': {'type': 'array', 'items': {r'$ref': r'#/$defs/row'}}},
      r'$defs': {'row': {
        'type': 'object', 'properties': {'id': {'type': 'string', 'pattern': r'^[a-z]+$'}},
      }},
    };
    const value = {'rows': [{'id': 'PRIVATE_INVALID_VALUE'}]};
    expect(() => validateToolInput(value, schema, 'probe'), throwsA(
      isA<FormatException>()
        .having((error) => error.message, 'location', contains('/rows/0/id'))
        .having((error) => error.message, 'sanitized error', isNot(contains('PRIVATE_INVALID_VALUE'))),
    ));
  });

  test('tool inputs reject invalid and unresolved schemas synchronously', () {
    for (final schema in <Map<String, dynamic>>[
      {r'$ref': 'https://unavailable.invalid/schema'},
      {'type': 'string', 'minLength': -1},
    ]) {
      expect(() => validateToolInput('value', schema, 'probe'), throwsFormatException);
    }
  });

  test('updated tool schemas never reuse stale validation rules', () {
    final schema = <String, dynamic>{'enum': ['before']};
    validateToolInput('before', schema, 'probe');
    schema['enum'] = ['after'];
    expect(() => validateToolInput('after', schema, 'probe'), returnsNormally);
    expect(() => validateToolInput('before', schema, 'probe'), throwsFormatException);
  });
}
