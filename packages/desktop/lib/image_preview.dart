import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart' show CancellationToken;

import 'appearance.dart';
import 'image_context_menu.dart';

typedef PreviewImage = ({ImageProvider provider, String label});

Future<void> showImagePreview(BuildContext context, {required List<PreviewImage> images,
  required int initialIndex}) => showGeneralDialog<void>(
    context: context, barrierDismissible: true, barrierLabel: 'Close image preview',
    barrierColor: const Color(0xe6000000), transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => ImagePreview(images: List.of(images), initialIndex: initialIndex),
  );

class ImagePreview extends StatefulWidget {
  const ImagePreview({super.key, required this.images, required this.initialIndex});
  final List<PreviewImage> images;
  final int initialIndex;

  @override
  State<ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<ImagePreview> {
  final _lifetime = CancellationToken();
  late int _index = widget.initialIndex;

  void _move(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.images.length) return;
    setState(() => _index = next);
  }

  @override
  void dispose() {
    _lifetime.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.images[_index];
    final navigation = widget.images.length > 1;
    return CallbackShortcuts(bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
    }, child: Focus(autofocus: true, child: Semantics(namesRoute: true, label: 'Image preview',
      child: Material(type: MaterialType.transparency, child: Stack(children: [
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => Navigator.pop(context),
          child: Padding(padding: EdgeInsets.fromLTRB(navigation ? 80 : 32, 48, navigation ? 80 : 32, 32),
            child: Center(child: GestureDetector(onTap: () {}, onSecondaryTapUp: (event) =>
              unawaited(showImageContextMenu(context, image.provider, event.globalPosition, _lifetime)),
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image(
                key: ValueKey(_index), image: image.provider, fit: BoxFit.contain,
                semanticLabel: '${image.label} ${_index + 1} of ${widget.images.length}',
                frameBuilder: (_, child, frame, synchronous) => synchronous || frame != null ? child
                  : const Center(child: Icon(Icons.image_outlined, size: 20, color: Colors.white70,
                    semanticLabel: 'Loading image')),
                errorBuilder: (_, _, _) => const Center(child: Text('Could not load image',
                  style: TextStyle(fontSize: 13, color: Colors.white70))),
              )))),
          ),
        )),
        Positioned(top: 12, right: 12, child: _PreviewButton(label: 'Close image preview', icon: Icons.close,
          onPressed: () => Navigator.pop(context))),
        if (_index > 0) Positioned(left: 12, top: 0, bottom: 0, child: Center(child:
          _PreviewButton(label: 'Previous image', icon: Icons.chevron_left, onPressed: () => _move(-1)))),
        if (_index < widget.images.length - 1) Positioned(right: 12, top: 0, bottom: 0, child: Center(child:
          _PreviewButton(label: 'Next image', icon: Icons.chevron_right, onPressed: () => _move(1)))),
      ])),
    )));
  }
}

class _PreviewButton extends StatelessWidget {
  const _PreviewButton({required this.label, required this.icon, required this.onPressed});
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(color: desktopSidebar,
    borderRadius: BorderRadius.circular(20), elevation: 4,
    child: IconButton(tooltip: label, onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40), padding: EdgeInsets.zero,
      style: const ButtonStyle(animationDuration: Duration.zero, splashFactory: NoSplash.splashFactory),
      icon: Icon(icon, size: 20, color: desktopForeground)),
  );
}
