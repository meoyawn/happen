import 'package:protocol/protocol.dart';

// Names and arguments follow Codex's history namespace. This runtime has one
// agent per task; cross-agent history is not advertised.
const historyCatalog = <Json>[
  {
    'name': 'history__list_windows',
    'description': 'List durable context windows. Arguments: limit? (1..100), recent_first?, agent_name? (omit or /root). Returns window_id, item_count, first_seq, last_seq. Use opaque IDs unchanged.',
  },
  {
    'name': 'history__list_items',
    'description': 'List durable messages/tool records. Arguments: window_id?, limit? (1..200), recent_first?, role? (user/assistant/tool/system/developer), tool_name?, tool_namespace?, max_chars_per_item?, agent_name? (omit or /root). Returns item_id, window_id, seq, created_at, role, truncated_content, offset_chars, total_chars. Includes compacted-away history.',
  },
  {
    'name': 'history__read_item',
    'description': 'Read a bounded range of a durable item. Arguments: item_id (required), window_id (required), offset_chars? (zero based), limit_chars? (1..16000), agent_name? (omit or /root). Returns content and total_chars; repeat with a later offset to read more.',
  },
  {
    'name': 'history__search_contents',
    'description': 'Search durable history by case-sensitive literal substring. Arguments: query (required), window_id?, limit? (1..200), recent_first?, role?, tool_name?, tool_namespace?, agent_name? (omit or /root). Returns matching excerpts with item_id/window_id and offset_chars. For regex filtering, list/read bounded items then filter in JavaScript.',
  },
];

const mcpResourceMethods = {
  'list_mcp_resources': 'resources/list',
  'list_mcp_resource_templates': 'resources/templates/list',
  'read_mcp_resource': 'resources/read',
};
const mcpResourceCatalog = <Json>[
  {
    'name': 'list_mcp_resources',
    'description': 'List MCP resources. Arguments: server? (configured server name), cursor? (requires server). Returns resources with server, URI, and metadata; nextCursor or next_cursors indicate another page.',
  },
  {
    'name': 'list_mcp_resource_templates',
    'description': 'List parameterized MCP resources. Arguments: server?, cursor? (requires server). Returns resourceTemplates and pagination metadata.',
  },
  {
    'name': 'read_mcp_resource',
    'description': 'Read an MCP resource. Arguments: server (required, exact configured name), uri (required, obtained from resource discovery). Returns contents with text or blob data.',
  },
];
