import 'package:flutter/material.dart';

import 'session.dart';
import 'appearance.dart';
import 'provider_icon.dart';

String _modelLabel(String model) {
  if (!model.startsWith('gpt-')) return model;
  final words = model.substring(4).split('-');
  return [words.first, for (final word in words.skip(1))
    if (word.isNotEmpty) '${word[0].toUpperCase()}${word.substring(1)}'].join(' ');
}

String _effortLabel(String effort) => switch (effort) {
  'none' || 'off' => 'Off',
  'minimal' => 'Minimal',
  'low' => 'Light',
  'medium' => 'Medium',
  'high' => 'High',
  'xhigh' => 'Extra High',
  'max' => 'Max',
  _ => effort,
};

PopupMenuItem<String> _option(String value, String label, bool selected, bool enabled) => PopupMenuItem<String>(
  value: value, enabled: enabled,
  child: Row(children: [
    Expanded(child: Text(label)),
    if (selected) const Icon(Icons.check_rounded, size: 16),
  ]),
);

class ComposerModelPicker extends StatelessWidget {
  const ComposerModelPicker({super.key, required this.session, required this.enabled, this.target,
    required this.modelMenuKey, required this.effortMenuKey});
  final DesktopSession session;
  final bool enabled;
  final DesktopTask? target;
  final GlobalKey<PopupMenuButtonState<String>> modelMenuKey, effortMenuKey;

  @override
  Widget build(BuildContext context) {
    final selected = target ?? session.task;
    final canChangeModel = enabled && selected == null;
    final canChangeEffort = enabled && (selected == null || selected.reasoningUpdates);
    final efforts = session.modelFor(target)?['reasoning_levels'] as List? ?? const [];
    final model = target?.model ?? session.modelId ?? 'Model';
    final effort = session.effortFor(target);
    final provider = target?.provider ?? session.providerId;
    void chooseModel(String value) { if (canChangeModel) session.chooseModel(value); }
    void chooseEffort(String value) => session.chooseReasoning(value, target: target);
    const muted = Color(0xff626862);
    const heading = TextStyle(fontSize: 10, letterSpacing: 1, color: muted);
    final combined = LayoutBuilder(builder: (context, constraints) => PopupMenuButton<String>(
      key: modelMenuKey,
      tooltip: 'Model and reasoning effort',
      enabled: enabled,
      borderRadius: BorderRadius.circular(8),
      onSelected: (value) {
        if (value.startsWith('effort:')) {
          chooseEffort(value.substring(7));
        } else {
          chooseModel(value);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem<String>(enabled: false, height: 28, child: Text('MODEL', style: heading)),
        for (final model in session.models)
          _option(model['id'] as String, model['id'] as String,
            model['provider'] == provider && model['id'] == (target?.model ?? session.modelId), canChangeModel),
        if (selected != null) const PopupMenuItem<String>(enabled: false,
          child: Text('Start a new task to change models.')),
        if (efforts.isNotEmpty) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(enabled: false, height: 28, child: Text('REASONING EFFORT', style: heading)),
          for (final effort in efforts.cast<String>())
            _option('effort:$effort', _effortLabel(effort), effort == session.effortFor(target), canChangeEffort),
          if (selected != null && !selected.reasoningUpdates)
            const PopupMenuItem<String>(enabled: false, child: Text('Reasoning effort is fixed for this task.')),
        ],
      ],
      child: SizedBox(height: 28, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(widthFactor: 1, heightFactor: 1, child: constraints.maxWidth < 120
          ? const Icon(Icons.tune_rounded, size: 16, color: muted)
          : ConstrainedBox(constraints: const BoxConstraints(maxWidth: 160), child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(_modelLabel(model), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, height: 18 / 13, color: muted))),
            if (effort != null) ...[
              const SizedBox(width: 6),
              Text(_effortLabel(effort), maxLines: 1, style: const TextStyle(fontSize: 13, height: 18 / 13, color: muted)),
            ],
          ])),
        ),
      )),
    ));
    const labelStyle = TextStyle(fontSize: 13, height: 20 / 13, letterSpacing: -.04,
      color: opencodeMuted, fontVariations: [FontVariation('wght', 440)]);
    Widget control(String label) => SizedBox(height: 28, child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle)),
      ])));
    return LayoutBuilder(builder: (context, constraints) => constraints.maxWidth < 140 ? combined : Row(
      mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: PopupMenuButton<String>(key: modelMenuKey, tooltip: 'Model', enabled: enabled,
          onSelected: chooseModel,
          itemBuilder: (_) => [
            for (final model in session.models) _option(model['id'] as String, model['id'] as String,
              model['provider'] == provider && model['id'] == (target?.model ?? session.modelId), canChangeModel),
            if (selected != null) const PopupMenuItem<String>(enabled: false,
              child: Text('Start a new task to change models.')),
          ], child: Row(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.only(left: 6),
              child: providerIcon(provider, size: 15, color: const Color(0xff797986))),
            Flexible(child: control(_modelLabel(model))),
          ]))),
        if (efforts.isNotEmpty && effort != null) PopupMenuButton<String>(key: effortMenuKey,
          tooltip: 'Reasoning effort', enabled: enabled,
          onSelected: chooseEffort,
          itemBuilder: (_) => [
            for (final effort in efforts.cast<String>()) _option(effort, _effortLabel(effort),
              effort == session.effortFor(target), canChangeEffort),
            if (!canChangeEffort) const PopupMenuItem<String>(enabled: false,
              child: Text('Reasoning effort is fixed for this task.')),
          ], child: control(_effortLabel(effort))),
      ],
    ));
  }
}
