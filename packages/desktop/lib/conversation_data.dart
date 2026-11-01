import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

class ConversationDataScope extends InheritedWidget {
  const ConversationDataScope({super.key, required this.client, this.providers = const [], required super.child});
  final AgentClient client;
  final List<Json> providers;

  @override
  bool updateShouldNotify(ConversationDataScope oldWidget) => client != oldWidget.client || providers != oldWidget.providers;
}

/// Like OpenCode's media references, large parts are read only when mounted.
/// Collapsed tool disclosures and offscreen images never request their bodies.
class ConversationData extends StatefulWidget {
  const ConversationData({super.key, required this.value, required this.builder});
  final Object? value;
  final Widget Function(BuildContext context, Object? value) builder;

  @override
  State<ConversationData> createState() => _ConversationDataState();
}

class _ConversationDataState extends State<ConversationData> {
  CancellationToken? _read;
  String? _reference;
  AgentClient? _client;
  Object? _value;
  bool _loading = false, _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ConversationData oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final value = widget.value;
    final reference = value is Map && value[r'$part'] is String ? value[r'$part'] as String : null;
    final client = context.dependOnInheritedWidgetOfExactType<ConversationDataScope>()?.client;
    if (reference == null) {
      _read?.cancel();
      _reference = null;
      _value = value;
      _loading = _failed = false;
    } else if (_reference != reference || _client != client) {
      _reference = reference;
      _client = client;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    _read?.cancel();
    final read = _read = CancellationToken();
    _value = null;
    _loading = true;
    _failed = false;
    try {
      final client = _client;
      if (client == null) throw StateError('Conversation is disconnected');
      final value = await client.conversationPart(_reference!, cancellation: read);
      if (mounted && !read.isCancelled) setState(() { _value = value; _loading = false; });
    } on CancelledException {
      // Leaving the viewport or changing a part cancels its read.
    } catch (_) {
      if (mounted && !read.isCancelled) setState(() { _loading = false; _failed = true; });
    }
  }

  @override
  void dispose() {
    _read?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(padding: EdgeInsets.all(12),
        child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 1.5)));
    }
    if (_failed) {
      return TextButton(onPressed: () { unawaited(_load()); setState(() {}); },
        child: const Text('Could not load content. Retry'));
    }
    return widget.builder(context, _value);
  }
}
