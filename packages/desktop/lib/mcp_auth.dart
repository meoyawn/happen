import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

Future<void> showMcpAuthentication(BuildContext context, AgentClient client, String server, {bool signOut = false}) async {
  await showDialog<void>(context: context, barrierDismissible: false,
    builder: (_) => _McpAuthentication(client: client, server: server, signOut: signOut));
}

class _McpAuthentication extends StatefulWidget {
  const _McpAuthentication({required this.client, required this.server, required this.signOut});
  final AgentClient client;
  final String server;
  final bool signOut;
  @override
  State<_McpAuthentication> createState() => _McpAuthenticationState();
}

class _McpAuthenticationState extends State<_McpAuthentication> {
  static const _desktop = MethodChannel('happen/desktop');
  final _lifetime = CancellationToken();
  CancellationToken? _attempt;
  StreamSubscription<Json>? _events;
  String? _url, _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    _attempt?.cancel();
    await _events?.cancel();
    if (!mounted) return;
    final token = _attempt = CancellationToken();
    final cancellation = token.merge(_lifetime);
    final id = newId();
    setState(() { _working = true; _error = null; _url = null; });
    if (!widget.signOut) {
      _events = widget.client.events.stream.listen((event) {
        if (event['type'] != 'mcp.auth.login' || event['server'] != widget.server || event['login_id'] != id || cancellation.isCancelled) return;
        setState(() => _url = event['url'] as String);
        unawaited(_openBrowser());
      });
    }
    try {
      if (widget.signOut) {
        await widget.client.mcpLogout(widget.server, cancellation: cancellation);
      } else {
        final result = await widget.client.mcpLogin(widget.server, id, cancellation: cancellation);
        if (result['state'] != 'ready') throw StateError('MCP connection is unavailable');
      }
      if (mounted && !cancellation.isCancelled) {
        await _desktop.invokeMethod<void>('activate');
        if (mounted) Navigator.of(context).pop();
      }
    } on CancelledException {
      // Closing the dialog or its client cancels discovery and the callback.
    } catch (_) {
      if (mounted && !cancellation.isCancelled) setState(() {
        _working = false;
        _error = widget.signOut ? 'Unable to sign out. Try again.' : 'Unable to sign in. Try again.';
      });
    }
  }

  Future<void> _openBrowser() async {
    final url = _url, token = _attempt;
    if (url == null || token == null || token.isCancelled || _lifetime.isCancelled) return;
    try {
      if (await _desktop.invokeMethod<bool>('openMcpLoginUrl', url) != true) throw StateError('Browser unavailable');
      if (mounted && !token.isCancelled) setState(() => _error = null);
    } catch (_) {
      if (mounted && !token.isCancelled) setState(() => _error = 'Could not open your default browser. Try Open browser again.');
    }
  }

  @override
  void dispose() {
    _lifetime.cancel();
    _attempt?.cancel();
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.signOut ? 'Sign out of' : 'Connect to'} ${widget.server}'),
    content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_working) Text(widget.signOut ? 'Signing out…' : _url == null ? 'Preparing sign-in…' : 'Complete sign-in in your default browser.'),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
        child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ])),
    actions: [
      if (_working && _url != null) TextButton(onPressed: () => unawaited(_openBrowser()), child: const Text('Open browser')),
      if (!_working) TextButton(onPressed: () => unawaited(_run()), child: const Text('Try again')),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(_working ? 'Cancel' : 'Close')),
    ],
  );
}
