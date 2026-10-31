const _nonemptyString = {'type': 'string', 'minLength': 1, 'pattern': r'\S'};
const _stringMap = {
  'type': 'object',
  'additionalProperties': {'type': 'string'},
};

/// The same embedded schema validates startup and reloads, including in AOT.
/// Provider-specific settings and model limits remain owned by each provider.
const globalConfigSchema = <String, Object?>{
  r'$schema': 'http://json-schema.org/draft-07/schema#',
  'title': 'Happen global configuration',
  'type': 'object',
  'additionalProperties': false,
  'properties': {
    'default_provider': {
      'enum': ['gpt', 'deepseek', 'opencode'],
    },
    'public_url': {'type': 'string', 'format': 'uri', 'pattern': r'^https://'},
    'providers': {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'gpt': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'model': _nonemptyString,
            'endpoint': {'type': 'string', 'format': 'uri'},
            'settings': {'type': 'object'},
          },
        },
        'deepseek': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'model': _nonemptyString,
            'endpoint': {'type': 'string', 'format': 'uri'},
            'api_key_env': _nonemptyString,
            'backend': {
              'enum': ['native', 'opencode'],
            },
            'transport': {
              'enum': ['messages', 'chat'],
            },
            'settings': {'type': 'object'},
          },
        },
        'opencode': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'model': _nonemptyString,
            'endpoint': {'type': 'string', 'format': 'uri'},
            'settings': {'type': 'object'},
          },
        },
      },
    },
    'mcp_servers': {
      'type': 'object',
      'maxProperties': 64,
      'propertyNames': _nonemptyString,
      'additionalProperties': {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'command': _nonemptyString,
          'args': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'cwd': _nonemptyString,
          'env': _stringMap,
          'inherit_env': {'type': 'array', 'items': _nonemptyString},
          'url': {'type': 'string', 'format': 'uri', 'pattern': r'^https?://'},
          'headers': _stringMap,
          'header_env': {
            'type': 'object',
            'additionalProperties': _nonemptyString,
          },
          'enabled': {'type': 'boolean'},
          'legacy_fallback': {'type': 'boolean'},
        },
        'oneOf': [
          {
            'required': ['command'],
          },
          {
            'required': ['url'],
          },
        ],
        'dependencies': {
          'args': ['command'],
          'cwd': ['command'],
          'env': ['command'],
          'inherit_env': ['command'],
          'headers': ['url'],
          'header_env': ['url'],
        },
      },
    },
  },
};
