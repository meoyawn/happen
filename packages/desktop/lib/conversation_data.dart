import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'session.dart' show conversationDataText;

class ConversationDataScope extends InheritedWidget {
  const ConversationDataScope({super.key, required this.client, this.providers = const [], required super.child});
  final AgentClient client;
  final List<Json> providers;
  @override
  bool updateShouldNotify(ConversationDataScope oldWidget) => client != oldWidget.client || providers != oldWidget.providers;
}

/// Native item payloads are self-contained. Expensive formatting, not a second
/// storage projection, is deferred until an expanded disclosure mounts.
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
  Object? _value;
  bool _loading = false;
  @override
  void initState() { super.initState(); _resolve(); }
  @override
  void didUpdateWidget(ConversationData oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.value, widget.value) || oldWidget.formatText != widget.formatText) _resolve();
  }
  void _resolve() {
    _work?.cancel();
    final value = widget.value;
    if (!widget.formatText || value == null) { _value = value; _loading = false; return; }
    if (value is String && value.length <= 1024) { _value = conversationDataText(value); _loading = false; return; }
    final work = _work = CancellationToken();
    _loading = true;
    unawaited(cancellableCompute(conversationDataText, value, work).then((text) {
      if (mounted && !work.isCancelled) setState(() { _value = text; _loading = false; });
    }).catchError((Object error) {
      if (mounted && !work.isCancelled) setState(() { _value = error.toString(); _loading = false; });
    }));
  }
  @override
  void dispose() { _work?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) => _loading ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5)) : widget.builder(context, _value);
}
