import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:openai/account_usage.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'browser.dart';
import 'desktop_menu.dart';
import 'openai_usage_controller.dart';

class OpenAIUsageMenu extends StatefulWidget {
  const OpenAIUsageMenu({super.key, required this.usage, required this.onManage});
  final OpenAIUsageController usage;
  final VoidCallback onManage;

  @override
  State<OpenAIUsageMenu> createState() => _OpenAIUsageMenuState();
}

class _OpenAIUsageMenuState extends State<OpenAIUsageMenu> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) => DesktopMenuAnchor(controller: _menu,
    style: MenuStyle(backgroundColor: const WidgetStatePropertyAll(desktopSurface),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      side: const WidgetStatePropertyAll(BorderSide(color: desktopBorder)),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(desktopPanelRadius)))),
    menuChildren: [SizedBox(width: 300, child: Padding(padding: const EdgeInsets.all(14),
      child: OpenAIUsageSection(usage: widget.usage, onManage: () {
        _menu.close();
        widget.onManage();
      })))],
    builder: (context, menu, focus) => IconButton(tooltip: 'Codex usage', focusNode: focus,
      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      style: IconButton.styleFrom(foregroundColor: desktopSecondary, minimumSize: const Size.square(28),
        padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: const Icon(Icons.bar_chart_rounded, size: 18)));
}

class OpenAIUsageSection extends StatefulWidget {
  const OpenAIUsageSection({super.key, required this.usage, this.onManage});
  final OpenAIUsageController usage;
  final VoidCallback? onManage;

  @override
  State<OpenAIUsageSection> createState() => _OpenAIUsageSectionState();
}

class _OpenAIUsageSectionState extends State<OpenAIUsageSection> {
  final _lifetime = CancellationToken();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.usage.refresh());
    });
  }

  @override
  void dispose() { _lifetime.cancel(); super.dispose(); }

  Future<void> _useReset(OpenAIAccountUsage usage, OpenAIUsageReset reset) async {
    final controller = widget.usage;
    final confirmed = await showDialog<bool>(context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use this Codex reset?'),
        scrollable: true,
        content: SizedBox(width: 320, child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, spacing: 8, children: [
            Text(reset.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(_resetExpiration(context, reset), style: const TextStyle(color: desktopSecondary)),
            if (reset.description case final description?) Text(description),
            const Text('This uses one of your available resets.', style: TextStyle(color: desktopSecondary)),
          ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ListenableBuilder(listenable: controller, builder: (context, _) => FilledButton(
            onPressed: controller.busy || !identical(usage, controller.usage) ? null
              : () => Navigator.pop(context, true),
            child: const Text('Confirm reset'))),
        ],
      ));
    if (confirmed == true) await controller.redeem(usage, reset);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.usage, builder: (context, _) {
    final controller = widget.usage;
    final usage = controller.usage;
    final notice = controller.notice;
    return DefaultTextStyle.merge(style: const TextStyle(fontSize: 12, color: desktopForeground),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Codex usage', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            if (usage?.plan case final plan?) Text('ChatGPT ${_planName(plan)}', style: _secondary),
          ])),
          IconButton(tooltip: 'Refresh usage', onPressed: controller.busy ? null : controller.refresh,
            style: IconButton.styleFrom(minimumSize: const Size.square(28), padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: desktopSecondary),
            icon: const Icon(Icons.refresh_rounded, size: 16)),
        ]),
        const SizedBox(height: 8),
        if (usage != null) ...[
          for (final window in usage.windows) Padding(padding: const EdgeInsets.only(bottom: 9), child: _window(context, window)),
          if (usage.unlimitedCredits)
            _row('Credits', 'Unlimited')
          else if (usage.creditBalance case final balance?)
            _row('Credits', '${_formatBalance(context, balance)} ${balance == 1 ? 'credit' : 'credits'}'),
          _row('Usage limit resets', switch (usage.resetCount) {
            final int count => '$count available',
            null when usage.resets.isNotEmpty => '${usage.resets.length} available',
            null => 'Unavailable',
          }),
          for (final reset in usage.resets) _resetRow(context, reset,
            onUse: controller.busy ? null : () => unawaited(_useReset(usage, reset))),
          if (!controller.busy && (usage.resetCount ?? 0) > usage.resets.length)
            const Text('Refresh to load all reset details.', style: _secondary),
        ],
        if (controller.busy) Padding(padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(controller.redeeming ? 'Using reset…' : 'Loading usage…', style: _secondary)),
        if (notice != null) Padding(padding: const EdgeInsets.only(top: 6), child: Semantics(liveRegion: true,
          child: Text(notice.message, style: TextStyle(color: notice.error ? desktopError : desktopSecondary)))),
        const Divider(height: 18, color: desktopBorder),
        Align(alignment: AlignmentDirectional.centerStart, child: TextButton(style: _actionStyle,
            onPressed: widget.onManage ?? () => unawaited(openDesktopLink(context, 'https://chatgpt.com/settings/usage',
              directory: '', cancellation: _lifetime)),
            child: Text(widget.onManage != null ? 'Manage usage' : 'Open usage dashboard'))),
      ]));
  });
}

const _secondary = TextStyle(fontSize: 11, color: desktopSecondary);

final _actionStyle = TextButton.styleFrom(minimumSize: const Size(0, 28),
  padding: const EdgeInsets.symmetric(horizontal: 8), tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  textStyle: const TextStyle(fontSize: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)));

Widget _row(String label, String value) => Padding(padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(children: [Expanded(child: Text(label)), const SizedBox(width: 8),
    Flexible(child: Text(value, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w500)))]));

Widget _resetRow(BuildContext context, OpenAIUsageReset reset, {VoidCallback? onUse}) => MergeSemantics(
  child: Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 2, children: [
      Text(reset.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
      Text(_resetExpiration(context, reset), style: _secondary),
    ])),
    const SizedBox(width: 8),
    OutlinedButton(style: _actionStyle, onPressed: onUse, child: const Text('Use reset')),
  ])));

Widget _window(BuildContext context, OpenAIUsageWindow window) => Column(crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    _row(switch (window.seconds) {
      604800 => 'Weekly limit',
      86400 => 'Daily limit',
      final seconds when seconds > 0 && seconds % 3600 == 0 => '${seconds ~/ 3600}-hour limit',
      final seconds when seconds >= 60 => '${seconds ~/ 60}-minute limit',
      final seconds => '$seconds-second limit',
    }, '${window.percentLeft}% left'),
    LinearProgressIndicator(value: window.percentLeft / 100, minHeight: 3,
      color: DesktopAccent.of(context).color, backgroundColor: desktopMuted,
      borderRadius: BorderRadius.circular(3), semanticsLabel: 'Usage remaining'),
    if (window.resetsAt case final at?) Padding(padding: const EdgeInsets.only(top: 4),
      child: Text('Resets ${_formatDate(context, at)}', style: _secondary)),
  ]);

String _formatDate(BuildContext context, DateTime at) {
  final local = at.toLocal(), labels = MaterialLocalizations.of(context);
  return '${labels.formatShortDate(local)} at ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

String _resetExpiration(BuildContext context, OpenAIUsageReset reset) => switch (reset.expiresAt) {
  final date? => 'Expires ${_formatDate(context, date)}',
  null => 'Expiration unavailable',
};

String _formatBalance(BuildContext context, num balance) => balance == balance.toInt()
  ? MaterialLocalizations.of(context).formatDecimal(balance.toInt()) : balance.toString();

String _planName(String plan) => switch (plan) {
  'prolite' => 'Pro',
  'team' => 'Business',
  'edu' => 'Edu',
  _ => plan.replaceAll('_', ' ').split(' ').where((word) => word.isNotEmpty)
    .map((word) => '${word[0].toUpperCase()}${word.substring(1)}').join(' '),
};
