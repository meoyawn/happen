// Generated from packages/config/schema.json.
// Run: dart packages/config/tool/generate_schema.dart
const globalConfigSchema = <String, Object?>{
  "\$id": "https://raw.githubusercontent.com/meoyawn/happen/master/packages/config/schema.json",
  "\$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Happen configuration",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "code_mode_tool_search": {
      "type": "boolean",
      "default": false,
      "description": "Enable ranked discovery of deferred tools in GPT code mode. Explicit thread settings take precedence."
    },
    "mcp_servers": {
      "type": "object",
      "maxProperties": 64,
      "propertyNames": {
        "type": "string",
        "minLength": 1,
        "pattern": "\\S"
      },
      "additionalProperties": {
        "allOf": [
          {
            "\$ref": "#/definitions/server"
          },
          {
            "oneOf": [
              {
                "required": [
                  "command"
                ]
              },
              {
                "required": [
                  "url"
                ]
              }
            ],
            "dependencies": {
              "args": [
                "command"
              ],
              "cwd": [
                "command"
              ],
              "env": [
                "command"
              ],
              "inherit_env": [
                "command"
              ],
              "headers": [
                "url"
              ],
              "header_env": [
                "url"
              ],
              "oauth": [
                "url"
              ]
            }
          }
        ]
      }
    }
  },
  "description": "Global tool discovery and MCP server configuration. Project layers configure icons and MCP servers; model and other host options are selected through their owning APIs.",
  "definitions": {
    "iconColor": {
      "enum": [
        "gray",
        "red",
        "orange",
        "amber",
        "yellow",
        "lime",
        "green",
        "emerald",
        "teal",
        "cyan",
        "sky",
        "blue",
        "indigo",
        "violet",
        "purple",
        "fuchsia",
        "pink",
        "rose"
      ]
    },
    "projectIcon": {
      "description": "A local image path (absolute or relative to the project directory), a Lucide icon, emoji, or monogram. Null restores the default icon.",
      "oneOf": [
        {
          "type": "null"
        },
        {
          "type": "string",
          "minLength": 1,
          "maxLength": 4096,
          "pattern": "\\S"
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "kind",
            "name",
            "color"
          ],
          "properties": {
            "kind": {
              "const": "lucide"
            },
            "name": {
              "type": "string",
              "minLength": 1,
              "maxLength": 100,
              "pattern": "^[a-z0-9]+(?:-[a-z0-9]+)*\$"
            },
            "color": {
              "\$ref": "#/definitions/iconColor"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "kind",
            "emoji"
          ],
          "properties": {
            "kind": {
              "const": "emoji"
            },
            "emoji": {
              "type": "string",
              "minLength": 1,
              "maxLength": 64,
              "pattern": "\\S"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "kind",
            "text",
            "color"
          ],
          "properties": {
            "kind": {
              "const": "monogram"
            },
            "text": {
              "type": "string",
              "pattern": "^[A-Z0-9]{1,2}\$"
            },
            "color": {
              "\$ref": "#/definitions/iconColor"
            }
          }
        }
      ]
    },
    "server": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "command": {
          "type": "string",
          "minLength": 1,
          "pattern": "\\S"
        },
        "args": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "cwd": {
          "type": "string",
          "minLength": 1,
          "pattern": "\\S"
        },
        "env": {
          "type": "object",
          "additionalProperties": {
            "type": "string"
          }
        },
        "inherit_env": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "pattern": "\\S"
          }
        },
        "url": {
          "type": "string",
          "format": "uri",
          "pattern": "^https?://[^/?#@\\s]+(?:[/?][^#\\s]*)?\$"
        },
        "headers": {
          "type": "object",
          "additionalProperties": {
            "type": "string"
          }
        },
        "header_env": {
          "type": "object",
          "additionalProperties": {
            "type": "string",
            "minLength": 1,
            "pattern": "\\S"
          }
        },
        "enabled": {
          "type": "boolean"
        },
        "legacy_fallback": {
          "type": "boolean"
        },
        "oauth": {
          "oneOf": [
            {
              "const": false
            },
            {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "client_id": {
                  "type": "string",
                  "minLength": 1,
                  "pattern": "\\S"
                },
                "client_secret_env": {
                  "type": "string",
                  "minLength": 1,
                  "pattern": "\\S"
                },
                "token_endpoint_auth_method": {
                  "enum": [
                    "none",
                    "client_secret_basic",
                    "client_secret_post"
                  ]
                },
                "scopes": {
                  "type": "array",
                  "items": {
                    "type": "string",
                    "minLength": 1,
                    "pattern": "\\S"
                  }
                },
                "callback_port": {
                  "type": "integer",
                  "minimum": 0,
                  "maximum": 65535
                }
              },
              "dependencies": {
                "client_secret_env": [
                  "client_id"
                ],
                "token_endpoint_auth_method": [
                  "client_id"
                ]
              }
            }
          ]
        }
      }
    },
    "project": {
      "title": "Happen project configuration",
      "description": "Project layers may override individual MCP server fields. Transports are validated after merging with global and ancestor layers.",
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "icon": {
          "\$ref": "#/definitions/projectIcon"
        },
        "mcp_servers": {
          "type": "object",
          "maxProperties": 64,
          "propertyNames": {
            "type": "string",
            "minLength": 1,
            "pattern": "\\S"
          },
          "additionalProperties": {
            "\$ref": "#/definitions/server"
          }
        }
      }
    }
  }
};
