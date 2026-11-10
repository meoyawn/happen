import 'dart:typed_data';

import 'package:config/config.dart';
import 'package:elk_stroke_icons/elk_stroke_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const projectIconColors = {
  'gray': Color(0xff4b5563), 'red': Color(0xffdc2626), 'orange': Color(0xffea580c),
  'amber': Color(0xffd97706), 'yellow': Color(0xffca8a04), 'lime': Color(0xff65a30d),
  'green': Color(0xff16a34a), 'emerald': Color(0xff059669), 'teal': Color(0xff0d9488),
  'cyan': Color(0xff0891b2), 'sky': Color(0xff0284c7), 'blue': Color(0xff2563eb),
  'indigo': Color(0xff4f46e5), 'violet': Color(0xff7c3aed), 'purple': Color(0xff9333ea),
  'fuchsia': Color(0xffc026d3), 'pink': Color(0xffdb2777), 'rose': Color(0xffe11d48),
};

/// File bytes arrive from a workspace worker; painting never reads the disk.
class ProjectIconMark extends StatelessWidget {
  const ProjectIconMark({super.key, required this.icon, this.size = 24, this.bytes, this.svg = false});
  final ProjectIcon icon;
  final double size;
  final Uint8List? bytes;
  final bool svg;

  @override
  Widget build(BuildContext context) {
    final mark = switch (icon) {
      ProjectGlyphIcon(:final name, :final color) => LucideIcon(
        IconSearchService.findByName(name) ?? LucideIcons.folderCode, size: size,
        color: projectIconColors[color]),
      ProjectEmojiIcon(:final emoji) => Center(child: Text(emoji,
        style: TextStyle(fontSize: size * .88, height: 1))),
      ProjectMonogramIcon(:final text, :final color) => DecoratedBox(
        decoration: BoxDecoration(color: projectIconColors[color]?.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(size * .22)),
        child: Center(child: Text(text, style: TextStyle(fontSize: size * (text.length == 1 ? .62 : .43),
          height: 1, fontWeight: FontWeight.w600, color: projectIconColors[color])))),
      ProjectFileIcon() => bytes == null ? _unavailable() : ClipRRect(
        borderRadius: BorderRadius.circular(size * .18), child: svg
          ? SvgPicture.memory(bytes!, width: size, height: size, fit: BoxFit.contain,
              errorBuilder: (_, _, _) => _unavailable())
          : Image.memory(bytes!, width: size, height: size, fit: BoxFit.contain, gaplessPlayback: true,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
              errorBuilder: (_, _, _) => _unavailable())),
    };
    return SizedBox.square(dimension: size, child: mark);
  }

  Widget _unavailable() => Icon(Icons.image_not_supported_outlined, size: size, color: const Color(0xff737373));
}
