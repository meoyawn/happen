import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appearance.dart';
import 'interface_mode.dart';
import 'project_avatar.dart';
import 'session.dart';
import 'window_chrome.dart';

const _pages = [
  (id: 'providers', label: 'Providers', icon: Icons.key_outlined,
    description: 'Manage the accounts you use for AI models'),
  (id: 'preferences', label: 'Preferences', icon: Icons.tune,
    description: 'Customize preferences and default behavior'),
  (id: 'appearance', label: 'Appearance', icon: Icons.palette_outlined,
    description: 'Customize how Happen looks'),
  (id: 'archived', label: 'Archived tasks', icon: Icons.archive_outlined,
    description: 'View past conversations or restore them to continue'),
];

// OpenCode: app/src/settings/{navigation.tsx,settings.css}; only supported pages are listed.
class DesktopSettingsScreen extends StatefulWidget {
  const DesktopSettingsScreen({super.key, required this.session, required this.accounts,
    required this.archived, required this.run, this.windowControls = true});
  final DesktopSession session;
  final Widget accounts, archived;
  final Future<void> Function(Future<void> Function()) run;
  final bool windowControls;

  @override
  State<DesktopSettingsScreen> createState() => _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState extends State<DesktopSettingsScreen> {
  String _page = 'preferences';
  final _scroll = ScrollController();

  void _select(String page) {
    if (_page == page) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _page = page);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _back(BuildContext context) => TextButton.icon(
    onPressed: () => Navigator.pop(context),
    style: _navStyle(),
    icon: const Icon(Icons.arrow_back, size: 16),
    label: const Text('Back to app'));

  @override
  Widget build(BuildContext context) {
    final page = _pages.firstWhere((page) => page.id == _page);
    return Focus(autofocus: true, onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      unawaited(Navigator.maybePop(context));
      return KeyEventResult.handled;
    }, child: Scaffold(backgroundColor: const Color(0xfffafafa), body: Column(children: [
      DesktopWindowDragRegion(child: SizedBox(height: widget.windowControls ? 40 : 8, width: double.infinity)),
      Expanded(child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x0d000000), width: .5),
          boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 3, offset: Offset(0, 1))]),
        child: Material(color: Colors.white, child: LayoutBuilder(builder: (context, bounds) {
          final wide = bounds.maxWidth >= 768;
          final gutter = ((bounds.maxWidth - 1048) / 2).clamp(0.0, double.infinity);
          final content = SingleChildScrollView(controller: _scroll,
            padding: EdgeInsets.fromLTRB(wide ? 4 : 24, wide ? 48 : 24, wide ? 4 : 24, 80),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(page.label, style: const TextStyle(fontSize: 15, height: 20 / 15,
                fontWeight: FontWeight.w600, color: opencodeInk)),
              const SizedBox(height: 4),
              Text(page.description, style: const TextStyle(fontSize: 11, height: 16 / 11, color: opencodeMuted)),
              const SizedBox(height: 24),
              if (widget.session.loginSucceeded) ...[
                Container(padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: const Color(0xffe3f1e8), borderRadius: BorderRadius.circular(8)),
                  child: Text('Signed in to ${widget.session.loginProvider == 'openai' ? 'ChatGPT' : 'OpenCode'}. Your account is connected.',
                    style: const TextStyle(fontSize: 13, color: Color(0xff296748)))),
                const SizedBox(height: 24),
              ],
              switch (_page) {
                'providers' => widget.accounts,
                'appearance' => _appearance(),
                'archived' => widget.archived,
                _ => _preferences(),
              },
              if (widget.session.error case final error?)
                Padding(padding: const EdgeInsets.only(top: 20), child: SelectableText(error,
                  style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.error))),
            ]));
          if (!wide) {
            return Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(18, 12, 18, 0), child: Row(children: [
              Tooltip(message: 'Back', child: _back(context)),
              const Spacer(),
              PopupMenuButton<String>(tooltip: 'Settings pages', initialValue: _page, onSelected: _select,
                itemBuilder: (_) => [for (final item in _pages)
                  PopupMenuItem(value: item.id, child: Text(item.label))],
                child: Padding(padding: const EdgeInsets.all(6), child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(page.label, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 6), const Icon(Icons.keyboard_arrow_down, size: 16),
                ]))),
            ])),
            Expanded(child: content),
            ]);
          }
          return Padding(padding: EdgeInsets.symmetric(horizontal: gutter), child: Row(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 328, child: Padding(padding: const EdgeInsets.fromLTRB(24, 50, 64, 48),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Tooltip(message: 'Back', child: _back(context)),
                  const SizedBox(height: 44),
                  Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final item in _pages) ...[
                      if (item.id == 'preferences' || item.id == 'archived') const SizedBox(height: 16),
                      Padding(padding: const EdgeInsets.only(bottom: 4), child: TextButton.icon(
                        onPressed: () => _select(item.id),
                        style: _navStyle(selected: _page == item.id),
                        icon: Icon(item.icon, size: 16), label: Text(item.label))),
                    ],
                  ]))),
                ]))),
              Expanded(child: content),
            ]));
        })),
      )),
    ])));
  }

  Widget _preferences() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    OpenCodeInterfacePicker(selected: widget.session.openCodeLayout,
      onSelected: (layout) => unawaited(widget.run(() => widget.session.chooseOpenCodeLayout(layout)))),
    const SizedBox(height: 32),
    _settingsList([
      _settingsRow('Messages sent while a task is working', widget.session.deliveryMode == 'steer'
          ? 'Guide the current turn at the next model step.'
          : 'Wait for the current turn to finish, then start the next one.',
        _choice('Follow-up behavior', widget.session.deliveryMode, const {'steer': 'Steer', 'queue': 'Queue'},
          (value) => widget.run(() => widget.session.chooseDeliveryMode(value)))),
      _settingsRow('Dictation', widget.session.dictationMode == 'live'
          ? 'Show text while you speak. If live dictation is unavailable, transcribe when you stop.'
          : 'Record first, then insert the transcription when you stop.',
        _choice('Dictation', widget.session.dictationMode, const {'live': 'Live', 'on_stop': 'On stop'},
          (value) => widget.run(() => widget.session.chooseDictationMode(value)))),
    ]),
  ]);

  Widget _appearance() => _settingsList([
    _settingsRow('Project icons', 'Choose the marks shown beside your projects.',
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (widget.session.project case final project?) ...[
          ProjectAvatar(project: project, size: 24, generated: widget.session.projectAvatarStyle == 'generated'),
          const SizedBox(width: 12),
        ],
        _choice('Project icons', widget.session.projectAvatarStyle, const {'letters': 'Letters', 'generated': 'Generated'},
          (value) => widget.run(() => widget.session.chooseProjectAvatarStyle(value))),
      ])),
    for (final project in widget.session.projects.where((project) => !project.removing))
      _settingsRow(project.name, project.path, Row(mainAxisSize: MainAxisSize.min, children: [
        ProjectAvatar(project: project, size: 24, generated: widget.session.projectAvatarStyle == 'generated'),
        const SizedBox(width: 16),
        SizedBox(width: 244, child: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
          for (final color in opencodeProjectColors.keys) _projectColor(project, color),
        ])),
      ])),
  ]);

  Widget _projectColor(Project project, String color) {
    final selected = (project.avatarColor ?? 'gray') == color;
    return Tooltip(message: 'Use $color for ${project.name}', child: Semantics(selected: selected,
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), boxShadow: selected ? const [
          BoxShadow(color: opencodeInk, spreadRadius: 4),
          BoxShadow(color: Color(0xfffafafa), spreadRadius: 2),
        ] : null),
        child: InkWell(borderRadius: BorderRadius.circular(6),
          onTap: () => unawaited(widget.run(() => widget.session.chooseProjectAvatarColor(project, selected ? null : color))),
          child: SizedBox.square(dimension: 20, child: Stack(alignment: Alignment.center, children: [
            ProjectAvatar(project: project, color: color, label: '', size: 20),
            if (selected) const Icon(Icons.check, size: 14, color: Colors.white),
          ]))),
      )));
  }
}

ButtonStyle _navStyle({bool selected = false}) => TextButton.styleFrom(
  visualDensity: VisualDensity.standard,
  alignment: Alignment.centerLeft,
  foregroundColor: selected ? opencodeInk : opencodeMuted,
  backgroundColor: selected ? const Color(0xffeeeeee) : Colors.transparent,
  textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w400),
  minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 6),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)));

Widget _settingsList(List<Widget> rows) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 20),
  decoration: BoxDecoration(color: const Color(0xfffafafa), borderRadius: BorderRadius.circular(8),
    border: Border.all(color: const Color(0x14000000), width: .5)),
  child: Column(children: [for (var index = 0; index < rows.length; index++) ...[
    if (index > 0) const Divider(height: .5, thickness: .5, color: opencodeBorder),
    rows[index],
  ]]));

Widget _settingsRow(String title, String description, Widget control) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 20),
  child: LayoutBuilder(builder: (context, bounds) {
    final copy = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500, color: opencodeInk)),
      const SizedBox(height: 4),
      Text(description, style: const TextStyle(fontSize: 13, height: 20 / 13, color: opencodeMuted)),
    ]);
    if (bounds.maxWidth < 420) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        copy, const SizedBox(height: 16), Align(alignment: Alignment.centerRight, child: control),
      ]);
    }
    return Row(children: [Expanded(child: copy), const SizedBox(width: 16), control]);
  }));

Widget _choice(String label, String value, Map<String, String> options, ValueChanged<String> onChanged) =>
  Semantics(label: label, child: Container(
    height: 28,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0x1f000000), width: .5)),
    child: DropdownButtonHideUnderline(child: DropdownButton<String>(
      value: value, isDense: true, borderRadius: BorderRadius.circular(6),
      padding: EdgeInsets.zero,
      dropdownColor: Colors.white,
      style: const TextStyle(fontFamily: 'Inter', fontSize: 13, height: 16 / 13, color: opencodeInk),
      icon: const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.keyboard_arrow_down, size: 14, color: opencodeMuted)),
      items: [for (final entry in options.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
      onChanged: (value) { if (value != null) onChanged(value); },
    ))));
