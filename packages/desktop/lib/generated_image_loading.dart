import 'package:flutter/material.dart';

import 'appearance.dart';

class GeneratedImageLoading extends StatelessWidget {
  const GeneratedImageLoading({super.key, this.thumbnail = false});
  final bool thumbnail;

  @override
  Widget build(BuildContext context) => Semantics(label: 'Generating image…', liveRegion: true,
    child: DecoratedBox(decoration: BoxDecoration(color: desktopMuted,
      borderRadius: BorderRadius.circular(thumbnail ? 8 : 16)),
      child: LayoutBuilder(builder: (context, constraints) => Center(child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.image_outlined, size: 20, color: desktopTertiary),
          if (!thumbnail && constraints.maxWidth >= 120 && constraints.maxHeight >= 64) ...[
            const SizedBox(height: 8),
            const Text('Generating image…', style: TextStyle(fontSize: 12, color: desktopSecondary)),
          ],
        ],
      ))),
    ),
  );
}
