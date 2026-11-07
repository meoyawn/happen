import 'dart:async';

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'appearance_preferences.dart';

const _accents = [
  (label: 'Blue', color: desktopDefaultAccent),
  (label: 'Violet', color: Color(0xff8b5cf6)),
  (label: 'Pink', color: Color(0xffd94680)),
  (label: 'Orange', color: Color(0xffea7c32)),
  (label: 'Green', color: Color(0xff29966f)),
  (label: 'Graphite', color: Color(0xff62666d)),
];

class DesktopAccentSettings extends StatefulWidget {
  const DesktopAccentSettings({super.key, required this.controller, required this.run});
  final AppearanceController controller;
  final Future<void> Function(Future<void> Function()) run;

  @override
  State<DesktopAccentSettings> createState() => _DesktopAccentSettingsState();
}

class _DesktopAccentSettingsState extends State<DesktopAccentSettings> {
  late final _hex = TextEditingController(text: desktopAccentHex(widget.controller.state.value));

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _choose(Color color) {
    setState(() => _hex.text = desktopAccentHex(color));
    unawaited(widget.run(() => widget.controller.choose(color)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final state = widget.controller.state;
    final enabled = state is AppearanceReady || state is AppearanceFailed;
    final pending = state is AppearanceSaving ? state.pending : state.value;
    final value = parseDesktopAccent(_hex.text);
    final valid = value != null;
    return Padding(padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Accent color', style: TextStyle(fontSize: 13, height: 16 / 13,
          fontWeight: FontWeight.w500, color: desktopForeground)),
        const SizedBox(height: 4),
        const Text('Choose the color for links, focus, and text selection.',
          style: TextStyle(fontSize: 13, height: 20 / 13, color: desktopSecondary)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final choice in _accents) Tooltip(message: choice.label,
            child: Semantics(label: '${choice.label} accent', selected: pending == choice.color,
              button: true, enabled: enabled, child: InkResponse(
                onTap: enabled ? () => _choose(choice.color) : null,
                mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
                radius: 18,
                child: Container(width: 28, height: 28, alignment: Alignment.center,
                  decoration: BoxDecoration(color: choice.color, shape: BoxShape.circle,
                    border: Border.all(color: pending == choice.color
                      ? desktopForeground : desktopBorderStrong,
                      width: pending == choice.color ? 2 : 1)),
                  child: pending == choice.color ? Icon(Icons.check, size: 15,
                    color: choice.color.computeLuminance() > .4
                      ? desktopForeground : desktopSurface) : null)))),
          SizedBox(width: 112, child: TextField(
            controller: _hex, enabled: enabled,
            style: const TextStyle(fontFamily: desktopMonoFamily, fontSize: 12),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) { if (enabled && valid) _choose(value); },
            decoration: InputDecoration(labelText: 'Hex color', hintText: '#339cff',
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(desktopControlRadius),
                borderSide: const BorderSide(color: desktopBorderStrong)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(desktopControlRadius),
                borderSide: BorderSide(color: DesktopAccent.of(context).reference))))),
          FilledButton(onPressed: enabled && valid && (value != state.value || state is AppearanceFailed)
            ? () => _choose(value) : null, child: const Text('Apply')),
          TextButton(onPressed: enabled && pending != desktopDefaultAccent
            ? () => _choose(desktopDefaultAccent) : null, child: const Text('Reset')),
        ]),
        if (!valid) const Padding(padding: EdgeInsets.only(top: 8),
          child: Text('Enter a hex color such as #339cff.',
            style: TextStyle(fontSize: 12, color: desktopError))),
        if (state is AppearanceSaving || state is AppearanceLoading) const Padding(padding: EdgeInsets.only(top: 8),
          child: Text('Saving accent color…', style: TextStyle(fontSize: 12, color: desktopSecondary))),
        if (state is AppearanceFailed) const Padding(padding: EdgeInsets.only(top: 8),
          child: Text('Could not save the accent color. Try again.',
            style: TextStyle(fontSize: 12, color: desktopError))),
      ]));
  });
}
