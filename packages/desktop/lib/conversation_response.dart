import 'package:flutter/material.dart';

import 'conversation_markdown.dart';
import 'session.dart';

/// Port of T3Code TimelineAssistantRows: a quiet copy/fork/timestamp action strip,
/// visible on hover or keyboard focus, without a second message projection.
class ConversationResponseFooter extends StatelessWidget {
  const ConversationResponseFooter({super.key, required this.entry, required this.visible, this.onFork, this.forking = false});
  final ChatEntry entry;
  final bool visible;
  final Future<void> Function()? onFork;
  final bool forking;

  @override
  Widget build(BuildContext context) {
    final timestamp = entry.timestamp;
    return AnimatedOpacity(opacity: visible ? 1 : 0, duration: const Duration(milliseconds: 200),
      alwaysIncludeSemantics: true, child: IgnorePointer(ignoring: !visible, child: Padding(
        padding: const EdgeInsets.only(top: 6), child: Row(mainAxisSize: MainAxisSize.min, children: [
          ConversationCopyButton(text: entry.text, label: 'Copy response', compact: true),
          if (onFork != null) SizedBox.square(dimension: 24,
            child: IconButton(tooltip: 'Fork from this response', onPressed: forking ? null : onFork,
              padding: EdgeInsets.zero, constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              visualDensity: VisualDensity.compact, iconSize: 14, icon: const Icon(Icons.fork_right_rounded))),
          if (timestamp != null) Padding(padding: const EdgeInsets.only(left: 8), child: Tooltip(message: timestamp.toLocal().toString(),
            child: Text('${timestamp.toLocal().hour.toString().padLeft(2, '0')}:${timestamp.toLocal().minute.toString().padLeft(2, '0')}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])))),
          if (entry.response?.interrupted == true) const Padding(padding: EdgeInsets.only(left: 8), child: Text('Interrupted', style: TextStyle(fontSize: 12))),
        ])),
      ));
  }
}
