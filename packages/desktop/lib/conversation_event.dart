import 'dart:convert';

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'conversation_activity.dart';
import 'conversation_markdown.dart';
import 'session.dart';

/// Event names and sources belong to their publisher. Payloads stay opaque:
/// displaying an event never depends on a particular provider or event schema.
class ConversationEventCard extends StatelessWidget {
  const ConversationEventCard({super.key, required this.event, this.timestamp,
    this.queued = false, this.actions, this.onExpand});
  final ChatEvent event;
  final DateTime? timestamp;
  final bool queued;
  final Widget? actions;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final at = event.timestamp ?? timestamp;
    final accent = DesktopAccent.of(context).color;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(border: Border.all(color: desktopBorderStrong),
        borderRadius: BorderRadius.circular(desktopPanelRadius)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 30, height: 30,
            decoration: BoxDecoration(color: accent.withValues(alpha: .1), borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.notifications_none_rounded, color: accent, size: 17)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(event.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w500)),
            const SizedBox(height: 3),
            Text('${queued ? 'Queued event' : 'Event received'} · ${event.source}',
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 1.5, color: desktopSecondary)),
          ])),
          if (at != null) Padding(padding: const EdgeInsets.only(left: 12, top: 2), child: Tooltip(
            message: at.toLocal().toString(),
            child: Text(MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(at.toLocal()),
              alwaysUse24HourFormat: true), style: const TextStyle(fontSize: 11, color: desktopTertiary,
                fontFeatures: [FontFeature.tabularFigures()])))),
        ]),
        Padding(padding: const EdgeInsets.only(left: 40, top: 8), child: ConversationDisclosure(
          key: const PageStorageKey('event-details'), label: 'Event details', fontSize: 12, onExpand: onExpand,
          builder: (context) {
            final payload = const JsonEncoder.withIndent('  ').convert(event.payload);
            return Container(
              width: double.infinity, padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: desktopSidebar, borderRadius: BorderRadius.circular(8)),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Text('Payload', style: TextStyle(fontSize: 11, color: desktopSecondary)),
                  const Spacer(), ConversationCopyButton(text: payload, label: 'Copy event', compact: true),
                ]),
                const SizedBox(height: 8),
                ConstrainedBox(constraints: const BoxConstraints(maxHeight: 280), child: SingleChildScrollView(
                  primary: false, child: SelectionArea(child: Text(payload,
                    style: const TextStyle(fontFamily: desktopMonoFamily, fontSize: 12, height: 1.6))))),
              ]),
            );
          },
        )),
        if (actions != null) Padding(padding: const EdgeInsets.only(left: 40, top: 8), child: actions!),
      ]),
    );
  }
}
