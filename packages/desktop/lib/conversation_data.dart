import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'session.dart' show StoredToolOutput, conversationDataText, conversationToolOutput;

class ConversationDataScope extends InheritedWidget {
  const ConversationDataScope({super.key, required this.client, this.providers = const [], required super.child});
  final AgentClient client;
  final List<Json> providers;
  @override
  bool updateShouldNotify(ConversationDataScope oldWidget) => client != oldWidget.client || providers != oldWidget.providers;
}

/// Large completed results and expensive formatting are loaded only while an
/// expanded disclosure is mounted.
class ConversationData extends StatefulWidget {
  const ConversationData({super.key, required this.value, required this.builder, this.formatText = false});
  final Object? value;
  final Widget Function(BuildContext context, Object? value) builder;
  final bool formatText;
  @override
  State<ConversationData> createState() => _ConversationDataState();
}

class _ConversationDataState extends State<ConversationData> {
  CancellationToken? _work;
  AgentClient? _client;
  Object? _value;
  bool _loading = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = context.dependOnInheritedWidgetOfExactType<ConversationDataScope>()?.client;
    if (_client != client || _work == null) { _client = client; _resolve(); }
  }
  @override
  void didUpdateWidget(ConversationData oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value || oldWidget.formatText != widget.formatText) _resolve();
  }
  void _resolve() {
    _work?.cancel();
    _work = null;
    final value = widget.value;
    _value = null;
    if (value is! StoredToolOutput) {
      if (!widget.formatText || value == null) { _value = value; _loading = false; return; }
      if (value is String && value.length <= 1024) { _value = conversationDataText(value); _loading = false; return; }
    }
    final work = _work = CancellationToken();
    _loading = true;
    unawaited(_load(value, work).then((resolved) {
      if (mounted && !work.isCancelled) setState(() { _value = resolved; _loading = false; });
    }).catchError((Object error) {
      if (mounted && !work.isCancelled) setState(() { _value = error.toString(); _loading = false; });
    }));
  }
  Future<Object?> _load(Object? value, CancellationToken work) async {
    if (value is StoredToolOutput) {
      final client = _client;
      if (client == null) throw StateError('Conversation history is unavailable');
      final result = await client.sessionRead('thread/item/read',
        {'threadId': value.threadId, 'turnId': value.turnId, 'itemId': value.itemId}, cancellation: work);
      work.throwIfCancelled();
      value = conversationToolOutput(jsonObject(result['item']));
    }
    return widget.formatText ? await cancellableCompute(conversationDataText, value, work) : value;
  }
  @override
  void dispose() { _work?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) => _loading ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5)) : widget.builder(context, _value);
}
