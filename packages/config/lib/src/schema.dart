const _nonemptyString = {'type': 'string', 'minLength': 1, 'pattern': r'\S'};
const _stringMap = {
  'type': 'object',
  'additionalProperties': {'type': 'string'},
};
const _webSearch = {
  'type': 'object',
  'additionalProperties': false,
  'properties': {
    'endpoint': {'type': 'string', 'format': 'uri', 'pattern': r'^https?://'},
  },
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
      'enum': ['openai', 'gpt', 'deepseek', 'opencode'],
    },
    'public_url': {'type': 'string', 'format': 'uri', 'pattern': r'^https://'},
    'providers': {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'openai': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'model': _nonemptyString,
            'endpoint': {'type': 'string', 'format': 'uri'},
            'settings': {'type': 'object'},
          },
        },
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
            'web_search': _webSearch,
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
            'web_search': _webSearch,
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
          'oauth': {
            'oneOf': [
              {'const': false},
              {
                'type': 'object', 'additionalProperties': false,
                'properties': {
                  'client_id': _nonemptyString,
                  'client_secret_env': _nonemptyString,
                  'token_endpoint_auth_method': {'enum': ['none', 'client_secret_basic', 'client_secret_post']},
                  'scopes': {'type': 'array', 'items': _nonemptyString},
                  'callback_port': {'type': 'integer', 'minimum': 0, 'maximum': 65535},
                },
                'dependencies': {'client_secret_env': ['client_id'], 'token_endpoint_auth_method': ['client_id']},
              },
            ],
          },
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
          'oauth': ['url'],
        },
      },
    },
  },
};
