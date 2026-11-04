import 'package:flutter/material.dart';

import 'conversation_markdown.dart';
import 'session.dart';

/// Port of T3Code TimelineAssistantRows: a quiet copy/timestamp action strip,
/// visible on hover or keyboard focus, without a second message projection.
class ConversationResponseFooter extends StatelessWidget {
  const ConversationResponseFooter({super.key, required this.entry, required this.visible});
  final ChatEntry entry;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final timestamp = entry.timestamp;
    return AnimatedOpacity(opacity: visible ? 1 : 0, duration: const Duration(milliseconds: 200),
      alwaysIncludeSemantics: true, child: IgnorePointer(ignoring: !visible, child: Padding(
        padding: const EdgeInsets.only(top: 6), child: Row(mainAxisSize: MainAxisSize.min, children: [
          ConversationCopyButton(text: entry.text, label: 'Copy response', compact: true),
          if (timestamp != null) Padding(padding: const EdgeInsets.only(left: 8), child: Tooltip(message: timestamp.toLocal().toString(),
            child: Text('${timestamp.toLocal().hour.toString().padLeft(2, '0')}:${timestamp.toLocal().minute.toString().padLeft(2, '0')}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])))),
          if (entry.response?.interrupted == true) const Padding(padding: EdgeInsets.only(left: 8), child: Text('Interrupted', style: TextStyle(fontSize: 12))),
        ])),
      ));
  }
}
