import 'package:protocol/protocol.dart';

const mcpEventMethods = {
  'list_mcp_events': 'events/list',
  'subscribe_mcp_events': 'mcp.events.subscribe',
  'list_mcp_event_subscriptions': 'mcp.events.subscriptions',
  'unsubscribe_mcp_events': 'mcp.events.unsubscribe',
};

const mcpEventCatalog = <Json>[
  {
    'name': 'list_mcp_events',
    'description': 'Discover native MCP event types, their subscription inputSchema, payloadSchema, and delivery modes. Omit server to list all configured servers. Use subscribe_mcp_events to watch events between turns.',
    'parameters': {'type': 'object', 'properties': {
      'server': {'type': 'string', 'description': 'Configured MCP server name. Omit to discover every server.'},
      'cursor': {'type': 'string', 'description': 'Opaque catalog pagination cursor; requires server.'},
    }, 'additionalProperties': false},
  },
  {
    'name': 'subscribe_mcp_events',
    'description': 'Subscribe this saved thread to a native MCP event type discovered with list_mcp_events. The running Happen server maintains delivery between turns and queues each occurrence as a new user input, waking the thread when idle. Arguments must follow the event inputSchema. No wait tool or active model run is needed. Check existing subscriptions before creating another watch.',
    'parameters': {'type': 'object', 'properties': {
      'server': {'type': 'string', 'minLength': 1},
      'name': {'type': 'string', 'minLength': 1, 'description': 'Exact event name from discovery.'},
      'arguments': {'type': 'object', 'description': 'Subscription filters and options described by the discovered inputSchema.'},
      'mode': {'type': 'string', 'enum': ['poll', 'push', 'webhook'], 'description': 'Optional delivery mode. Omit to let the host select one supported by this event.'},
      'cursor': {'type': 'string', 'description': 'Opaque resume cursor. Omit to watch from now.'},
      'max_age_ms': {'type': 'integer', 'minimum': 0, 'description': 'Bound replay age in milliseconds.'},
    }, 'required': ['server', 'name'], 'additionalProperties': false},
  },
  {
    'name': 'list_mcp_event_subscriptions',
    'description': 'List this thread\'s native MCP event subscriptions and their current state. Subscriptions belong to this thread and persist between turns.',
    'parameters': {'type': 'object', 'properties': {}, 'additionalProperties': false},
  },
  {
    'name': 'unsubscribe_mcp_events',
    'description': 'Stop a native MCP event subscription owned by this thread. Use the subscription_id returned by subscribe_mcp_events or list_mcp_event_subscriptions.',
    'parameters': {'type': 'object', 'properties': {
      'subscription_id': {'type': 'string', 'minLength': 1},
    }, 'required': ['subscription_id'], 'additionalProperties': false},
  },
];
