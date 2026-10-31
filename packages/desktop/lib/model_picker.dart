import 'package:flutter/material.dart';

import 'session.dart';

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
  const ComposerModelPicker({super.key, required this.session, required this.enabled});
  final DesktopSession session;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final canChangeModel = enabled && session.task == null;
    final canChangeEffort = enabled && (session.task == null || session.task!.reasoningUpdates);
    final efforts = session.modelInfo?['reasoning_levels'] as List? ?? const [];
    final model = session.modelId ?? 'Model';
    final effort = session.reasoning;
    const muted = Color(0xff626862);
    const heading = TextStyle(fontSize: 10, letterSpacing: 1, color: muted);
    return LayoutBuilder(builder: (context, constraints) => PopupMenuButton<String>(
      tooltip: 'Model and reasoning effort',
      enabled: enabled,
      borderRadius: BorderRadius.circular(8),
      onSelected: (value) {
        if (value.startsWith('effort:')) {
          session.chooseReasoning(value.substring(7));
        } else {
          session.chooseModel(value);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem<String>(enabled: false, height: 28, child: Text('MODEL', style: heading)),
        for (final model in session.models)
          _option(model['id'] as String, model['id'] as String, model['id'] == session.modelId, canChangeModel),
        if (session.task != null) const PopupMenuItem<String>(enabled: false,
          child: Text('Start a new task to change models.')),
        if (efforts.isNotEmpty) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(enabled: false, height: 28, child: Text('REASONING EFFORT', style: heading)),
          for (final effort in efforts.cast<String>())
            _option('effort:$effort', _effortLabel(effort), effort == session.reasoning, canChangeEffort),
          if (session.task != null && !session.task!.reasoningUpdates)
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
  }
}
