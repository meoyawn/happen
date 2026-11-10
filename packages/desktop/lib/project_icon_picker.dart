import 'dart:async';
import 'dart:io';

import 'package:config/config.dart';
import 'package:elk_stroke_icons/elk_stroke_icons.dart';
import 'package:flutter/material.dart';
import 'package:macos_file_picker/macos_file_picker.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'project_icon.dart';
import 'project_icon_state.dart';
import 'session.dart';

const _popular = ['folder-code', 'code-2', 'terminal', 'globe-2', 'server', 'database',
  'bot', 'sparkles', 'smartphone', 'monitor', 'cloud-cog', 'package', 'book-open',
  'flask-conical', 'shield-check', 'rocket', 'gamepad-2', 'music', 'image',
  'shopping-bag', 'git-branch', 'workflow', 'wrench', 'layers-3'];
const _emojis = [
  ('💻', 'Computer'), ('🛠️', 'Tools'), ('🚀', 'Rocket'), ('🤖', 'Robot'), ('✨', 'Sparkles'),
  ('⚡', 'Lightning'), ('🌐', 'Web'), ('📱', 'Mobile'), ('🖥️', 'Desktop'), ('⌨️', 'Keyboard'),
  ('⚙️', 'Gear'), ('🗄️', 'Database'), ('☁️', 'Cloud'), ('📦', 'Package'), ('📚', 'Books'),
  ('🧪', 'Test tube'), ('🔒', 'Lock'), ('🎮', 'Game'), ('🎵', 'Music'), ('🎬', 'Movie'),
  ('🖼️', 'Picture'), ('🛍️', 'Shopping'), ('🔥', 'Fire'), ('💡', 'Idea'), ('🧩', 'Puzzle'),
  ('📊', 'Chart'), ('🧠', 'Brain'), ('🦄', 'Unicorn'), ('🐙', 'Octopus'), ('🌱', 'Seedling'),
];

class ProjectIconPicker extends StatefulWidget {
  const ProjectIconPicker({super.key, required this.session, required this.project});
  final DesktopSession session;
  final Project project;
  @override
  State<ProjectIconPicker> createState() => _ProjectIconPickerState();
}

class _ProjectIconPickerState extends State<ProjectIconPicker> {
  final _lifetime = CancellationToken();
  CancellationToken? _fileRead;
  Timer? _debounce;
  late String _mode = switch (widget.project.icon) {
    ProjectEmojiIcon() => 'emoji', ProjectMonogramIcon() => 'monogram', ProjectFileIcon() => 'file', _ => 'lucide',
  };
  late String _iconName = switch (widget.project.icon) { ProjectGlyphIcon(:final name) => name, _ => 'folder-code' };
  late String _color = switch (widget.project.icon) {
    ProjectGlyphIcon(:final color) || ProjectMonogramIcon(:final color) => color, _ => 'blue',
  };
  late String _emoji = switch (widget.project.icon) { ProjectEmojiIcon(:final emoji) => emoji, _ => '💻' };
  late final _letters = TextEditingController(text: switch (widget.project.icon) {
    ProjectMonogramIcon(:final text) => text, _ => _monogram(widget.project.name),
  });
  late final _path = TextEditingController(text: switch (widget.project.icon) { ProjectFileIcon(:final path) => path, _ => '' });
  final _customEmoji = TextEditingController();
  String _query = '';
  bool _saving = false, _previewing = false;
  String? _fileError, _saveError;
  late ProjectIconSnapshot? _preview = widget.project.icon is ProjectFileIcon ? widget.project.iconState.value : null;

  ProjectIcon? get _draft => switch (_mode) {
    'lucide' => ProjectGlyphIcon(_iconName, _color),
    'emoji' => ProjectEmojiIcon(_emoji),
    'monogram' => RegExp(r'^[A-Z0-9]{1,2}$').hasMatch(_letters.text.trim().toUpperCase())
      ? ProjectMonogramIcon(_letters.text.trim().toUpperCase(), _color) : null,
    'file' => _path.text.trim().isEmpty ? null : ProjectFileIcon(_path.text.trim()),
    _ => null,
  };

  @override
  void dispose() {
    _lifetime.cancel(); _fileRead?.cancel(); _debounce?.cancel();
    _letters.dispose(); _path.dispose(); _customEmoji.dispose();
    super.dispose();
  }

  void _fileChanged() {
    _fileRead?.cancel(); _debounce?.cancel();
    setState(() { _preview = null; _fileError = null; _saveError = null; _previewing = _path.text.trim().isNotEmpty; });
    if (_previewing) _debounce = Timer(const Duration(milliseconds: 250), () => unawaited(_previewFile()));
  }

  Future<void> _previewFile() async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    _fileRead?.cancel();
    final token = _fileRead = CancellationToken();
    try {
      final preview = await widget.session.previewProjectIcon(widget.project, ProjectFileIcon(path),
        cancellation: token.merge(_lifetime));
      if (mounted && identical(_fileRead, token)) setState(() { _preview = preview; _fileError = preview.error; });
    } on CancelledException { /* A newer path or the dialog owns cancellation. */ }
    catch (error) {
      if (mounted && identical(_fileRead, token)) setState(() => _fileError = error.toString());
    } finally {
      if (mounted && identical(_fileRead, token)) setState(() => _previewing = false);
    }
  }

  Future<void> _browse() async {
    final paths = await MacosFilePicker().pick(MacosFilePickerMode.file, allowsMultiple: false,
      allowedUtiTypes: ['public.image', 'public.svg-image'], dialogTitle: 'Choose project icon');
    try {
      if (!mounted || paths == null || paths.isEmpty) return;
      final path = paths.first.path, prefix = '${widget.session.projectIconSource(widget.project)!.path}${Platform.pathSeparator}';
      _path.text = path.startsWith(prefix) ? path.substring(prefix.length) : path;
      _fileChanged();
    } finally { for (final path in paths ?? <MacosFilePickerPath>[]) { await path.release(); } }
  }

  Future<void> _save() async {
    final icon = _draft;
    if (_saving || icon == null) return;
    setState(() { _saving = true; _saveError = null; });
    try {
      await widget.session.chooseProjectIcon(widget.project, icon, cancellation: _lifetime);
      if (mounted) Navigator.pop(context);
    } on CancelledException { /* The owning dialog or session closed. */ }
    catch (error) { if (mounted) setState(() => _saveError = error.toString()); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    return PopScope(canPop: !_saving, child: Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 512,
        maxHeight: (MediaQuery.sizeOf(context).height - 64).clamp(200, 640)),
        child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Choose project icon', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(widget.project.name, style: const TextStyle(fontSize: 12, color: desktopSecondary)),
          ])), if (draft != null) ProjectIconMark(icon: draft, size: 40, bytes: _preview?.bytes, svg: _preview?.svg ?? false)]),
          const SizedBox(height: 24),
          SegmentedButton<String>(showSelectedIcon: false, segments: const [
            ButtonSegment(value: 'lucide', label: Text('Icons')),
            ButtonSegment(value: 'emoji', label: Text('Emoji')),
            ButtonSegment(value: 'monogram', label: Text('Monogram')),
            ButtonSegment(value: 'file', label: Text('File')),
          ], selected: {_mode}, onSelectionChanged: _saving ? null : (value) => setState(() { _mode = value.single; _saveError = null; }),
            style: const ButtonStyle(textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
              minimumSize: WidgetStatePropertyAll(Size(0, 36)),
              padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8, vertical: 12)))),
          const SizedBox(height: 20),
          Flexible(child: SingleChildScrollView(child: AbsorbPointer(absorbing: _saving,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_mode == 'lucide' || _mode == 'monogram') ...[_colors(), const SizedBox(height: 20)],
            switch (_mode) {
              'lucide' => _icons(), 'emoji' => _emojiChoices(), 'monogram' => _monogramInput(), _ => _fileInput(),
            },
          ])))),
          if (_saveError case final message?) Padding(padding: const EdgeInsets.only(top: 16),
            child: Text(message, style: const TextStyle(fontSize: 12, color: desktopError))),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(onPressed: _saving || draft == null || _mode == 'file' && (_previewing || _fileError != null)
              ? null : () => unawaited(_save()), child: Text(_saving ? 'Saving…' : 'Save icon')),
          ]),
        ])))));
  }

  Widget _colors() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Color', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
    const SizedBox(height: 8),
    Wrap(spacing: 6, runSpacing: 6, children: [for (final entry in projectIconColors.entries)
      Tooltip(message: entry.key, child: Semantics(selected: _color == entry.key, button: true,
        child: InkWell(onTap: () => setState(() => _color = entry.key), borderRadius: BorderRadius.circular(14),
          child: Container(width: 26, height: 26, padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(shape: BoxShape.circle,
              border: Border.all(color: _color == entry.key ? desktopForeground : Colors.transparent)),
            child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: entry.value)))))),
    ]),
  ]);

  Widget _icons() {
    final icons = _query.trim().isEmpty
      ? [for (final name in _popular) ?IconSearchService.findByName(name)]
      : IconSearchService.filter(_query.replaceAll(RegExp(r'\s+'), '-')).take(80).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(decoration: _input('Search all Lucide icons').copyWith(prefixIcon: const Icon(Icons.search, size: 18)),
        onChanged: (value) => setState(() => _query = value)),
      const SizedBox(height: 12),
      if (icons.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No icons found.', textAlign: TextAlign.center)),
      Wrap(spacing: 4, runSpacing: 4, children: [for (final icon in icons)
        _tile(icon.name, icon.name == (IconSearchService.findByName(_iconName)?.name ?? _iconName),
          LucideIcon(icon, size: 20, color: projectIconColors[_color]), () => setState(() => _iconName = icon.name)),
      ]),
    ]);
  }

  Widget _emojiChoices() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Wrap(spacing: 4, runSpacing: 4, children: [for (final (emoji, label) in _emojis)
      _tile(label, _emoji == emoji, Text(emoji, style: const TextStyle(fontSize: 22, height: 1)),
        () => setState(() { _emoji = emoji; _customEmoji.clear(); })),
    ]),
    const SizedBox(height: 16),
    TextField(controller: _customEmoji, decoration: _input('Or paste any emoji'), onChanged: (value) {
      final first = value.trim().characters.firstOrNull;
      if (first != null && first.runes.any((rune) => rune >= 0x1f000 && rune <= 0x1faff ||
          rune >= 0x2300 && rune <= 0x2bff || rune == 0x20e3 ||
          const {0xa9, 0xae, 0x203c, 0x2049, 0x2122, 0x2139, 0x3030, 0x303d, 0x3297, 0x3299}.contains(rune))) {
        setState(() => _emoji = first);
      }
    }),
  ]);

  Widget _monogramInput() => TextField(controller: _letters, textCapitalization: TextCapitalization.characters,
    decoration: _input('Letters').copyWith(helperText: 'One or two letters or numbers.',
      errorText: _draft == null ? 'Enter one or two letters or numbers.' : null),
    onChanged: (_) => setState(() {}));

  Widget _fileInput() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('Use a local SVG, PNG, or another image file.', style: TextStyle(fontSize: 13)),
    const SizedBox(height: 12),
    TextField(key: const ValueKey('project-icon-path'), controller: _path,
      decoration: _input('File path').copyWith(hintText: 'assets/logo.svg or /path/to/icon.png'),
      onChanged: (_) => _fileChanged()),
    const SizedBox(height: 8),
    const Text('Relative paths start in the project directory. The file stays where it is.',
      style: TextStyle(fontSize: 12, height: 1.5, color: desktopSecondary)),
    const SizedBox(height: 12),
    Row(children: [
      if (Platform.isMacOS && widget.session.projectIconSource(widget.project) != null)
        OutlinedButton.icon(onPressed: () => unawaited(_browse()), icon: const Icon(Icons.folder_open_outlined, size: 16),
          label: const Text('Choose file')),
      if (_previewing) const Padding(padding: EdgeInsets.only(left: 12),
        child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))),
    ]),
    if (_fileError ?? _preview?.error case final message?) Padding(padding: const EdgeInsets.only(top: 12),
      child: Text(message, style: const TextStyle(fontSize: 12, color: desktopError))),
  ]);

  Widget _tile(String label, bool selected, Widget child, VoidCallback onPressed) => Tooltip(message: label,
    child: Semantics(selected: selected, child: SizedBox.square(dimension: 40, child: OutlinedButton(
      onPressed: onPressed, style: OutlinedButton.styleFrom(padding: EdgeInsets.zero,
        backgroundColor: selected ? desktopMuted : Colors.transparent,
        side: BorderSide(color: selected ? desktopBorderStrong : Colors.transparent),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))), child: child))));
}

InputDecoration _input(String label) => InputDecoration(labelText: label, isDense: true,
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)));

String _monogram(String name) {
  final letters = name.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return letters.isEmpty ? 'P' : letters.length == 1 ? letters : '${letters[0]}${letters[letters.length - 1]}';
}
