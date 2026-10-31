import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'mcp_auth.dart';

/// Live connection requests belong to the conversation surface, not its saved
/// messages. Sign-in never sends a prompt or exposes credentials to the model.
class McpConversationAuth extends StatefulWidget {
  const McpConversationAuth({super.key, required this.client});
  final AgentClient client;
  @override
  State<McpConversationAuth> createState() => _McpConversationAuthState();
}

class _McpConversationAuthState extends State<McpConversationAuth> with WidgetsBindingObserver {
  final _lifetime = CancellationToken();
  CancellationToken? _request;
  StreamSubscription<Json>? _events;
  List<Json> _servers = [];
  final _active = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _events = widget.client.events.stream.listen((event) {
      if (const {'mcp.config.reloaded', 'mcp.config.error', 'mcp.auth.changed'}.contains(event['type'])) unawaited(_refresh());
    });
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    _request?.cancel();
    final token = _request = CancellationToken();
    try {
      final result = await widget.client.mcpInventory(cancellation: token.merge(_lifetime));
      if (mounted && !token.isCancelled) {
        setState(() {
          _servers = (result['servers'] as List).map(jsonObject).where((server) => server['oauth_supported'] == true &&
            (const {'not_authenticated', 'signing_in'}.contains(server['auth_status']) || _active.contains(server['name']))).toList();
          _active.retainAll(_servers.map((server) => server['name'] as String));
        });
      }
    } on CancelledException { /* Newer discovery or the conversation lifetime superseded this read. */
    } catch (_) { /* Connection errors already have their own desktop status. Keep the last accepted snapshot. */
    } finally { if (identical(_request, token)) _request = null; }
  }

  @override
  void dispose() {
    _lifetime.cancel();
    _request?.cancel();
    unawaited(_events?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_servers.isEmpty) return const SizedBox.shrink();
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 880), child: Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: const Color(0xffdaddd5)), borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 240), child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            const Text('MCP sign-in required', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Connect a server to make its tools available in this conversation.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            for (final server in _servers) Padding(
              key: ValueKey('mcp-auth:${server['name']}'),
              padding: const EdgeInsets.only(top: 10),
              child: _active.contains(server['name'])
                ? McpAuthenticationCard(client: widget.client, server: server['name'] as String, onDone: () {
                    if (mounted) setState(() => _active.remove(server['name']));
                    unawaited(_refresh());
                  })
                : Row(children: [
                    const Icon(Icons.extension_outlined, size: 16), const SizedBox(width: 8),
                    Expanded(child: Text(server['name'] as String)),
                    TextButton(onPressed: server['auth_status'] == 'signing_in' ? null
                      : () => setState(() => _active.add(server['name'] as String)),
                      child: Text(server['auth_status'] == 'signing_in' ? 'Waiting for browser…' : 'Sign in')),
                  ]),
            ),
          ]),
        )),
      ),
    )));
  }
}
