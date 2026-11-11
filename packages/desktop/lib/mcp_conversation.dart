import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'appearance.dart';
import 'mcp_auth.dart';

/// Live connection requests belong to the conversation surface, not its saved
/// messages. Sign-in never sends a prompt or exposes credentials to the model.
class McpConversationAuth extends StatefulWidget {
  const McpConversationAuth({super.key, required this.client, required this.cwd});
  final AgentClient client;
  final String cwd;
  @override
  State<McpConversationAuth> createState() => _McpConversationAuthState();
}

class _McpConversationAuthState extends State<McpConversationAuth> with WidgetsBindingObserver {
  final _lifetime = CancellationToken();
  CancellationToken? _request;
  StreamSubscription<Json>? _events;
  List<Json> _servers = [];
  final _active = <String>{};
  final _dismissed = <String>{};
  bool _expanded = false;

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
      final result = await widget.client.mcpInventory(cwd: widget.cwd, cancellation: token.merge(_lifetime));
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
    return Visibility(visible: !_servers.every((server) => _dismissed.contains(server['name'])), maintainState: true,
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 880), child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: desktopBorder), borderRadius: BorderRadius.circular(desktopControlRadius)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Semantics(button: true, expanded: _expanded, child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(desktopControlRadius),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: [
                  const Icon(Icons.extension_outlined, size: 14, color: desktopSecondary),
                  const SizedBox(width: 8),
                  Expanded(child: Text('MCP connections · ${_servers.length} awaiting sign-in',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: desktopSecondary))),
                  const SizedBox(width: 8),
                  Icon(_expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded,
                    size: 16, color: desktopTertiary),
                ])),
              ))),
              IconButton(tooltip: 'Dismiss MCP sign-in requests', iconSize: 14,
                constraints: const BoxConstraints.tightFor(width: 32, height: 32), padding: const EdgeInsets.all(8),
                onPressed: () => setState(() {
                  _expanded = false;
                  _dismissed..clear()..addAll(_servers.map((server) => server['name'] as String));
                }),
                icon: const Icon(Icons.close_rounded, color: desktopTertiary)),
              const SizedBox(width: 4),
            ]),
            Visibility(visible: _expanded, maintainState: true,
              child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 192), child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  const Text('Connect a server to make its tools available in this conversation.', style: TextStyle(fontSize: 12, color: desktopSecondary)),
                  for (final server in _servers) Padding(
                    key: ValueKey('mcp-auth:${server['name']}'),
                    padding: const EdgeInsets.only(top: 10),
                    child: _active.contains(server['name'])
                      ? McpAuthenticationCard(client: widget.client, server: server['name'] as String, cwd: widget.cwd, onDone: () {
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
              ))),
          ]),
        ),
      ))));
  }
}
