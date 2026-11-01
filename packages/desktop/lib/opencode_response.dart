import 'package:flutter/material.dart';

import 'appearance.dart';
import 'conversation_data.dart';
import 'conversation_markdown.dart';
import 'session.dart';

// OpenCode session-ui/message/message-content.tsx: round seconds, then m/s.
String? opencodeTurnDuration(Duration? duration) {
  if (duration == null || duration.isNegative) return null;
  final seconds = (duration.inMilliseconds / 1000).round();
  return seconds < 60 ? '${seconds}s' : '${seconds ~/ 60}m ${seconds % 60}s';
}

/// OpenCode's final-response footer, including its 20px copy target and hover.
class OpenCodeResponseFooter extends StatelessWidget {
  const OpenCodeResponseFooter({super.key, required this.entry, required this.visible});
  final ChatEntry entry;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final response = entry.response!;
    final providers = context.dependOnInheritedWidgetOfExactType<ConversationDataScope>()?.providers ?? const [];
    final provider = providers.where((value) => value['id'] == response.provider).firstOrNull;
    final models = provider?['models'] as List? ?? const [];
    final model = models.where((value) => value['id'] == response.model).firstOrNull;
    final name = model?['name'] as String? ?? response.model;
    final reasoning = response.reasoning;
    final variant = reasoning == null || reasoning.isEmpty || reasoning == 'default' ? null
      : '${reasoning[0].toUpperCase()}${reasoning.substring(1)}';
    final duration = opencodeTurnDuration(response.duration);
    final wide = MediaQuery.sizeOf(context).width >= 768;
    const style = TextStyle(fontSize: 12, height: 18 / 12, letterSpacing: .05,
      color: opencodeFaint, fontVariations: [FontVariation('wght', 440)]);
    final meta = <Widget>[
      if (wide && name != null && name.isNotEmpty) Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      if (wide && variant != null) ...[const SizedBox(width: 4), Text(variant)],
      if (duration != null) ...[
        if (wide && name != null && name.isNotEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text('·')),
        Text(duration),
      ],
      if (response.interrupted) ...[
        if (duration != null || wide && name != null && name.isNotEmpty)
          const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text('·')),
        const Text('Interrupted'),
      ],
    ];
    return Padding(padding: const EdgeInsets.only(top: 8), child: SizedBox(height: 20,
      child: Opacity(opacity: visible ? 1 : 0, alwaysIncludeSemantics: true,
        child: IgnorePointer(ignoring: !visible, child: DefaultTextStyle.merge(style: style,
          child: Row(mainAxisAlignment: response.interrupted ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
            Transform.translate(offset: const Offset(-2, 0), child: ConversationCopyButton(
              text: entry.text, label: 'Copy response', compact: true)),
            if (meta.isNotEmpty) ...[const SizedBox(width: 4), Flexible(child: Row(mainAxisSize: MainAxisSize.min, children: meta))],
          ]),
        )),
      ),
    ));
  }
}
