import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:protocol/protocol.dart';

import 'desktop_toast.dart';
import 'image_clipboard.dart';

Future<void> showImageContextMenu(BuildContext context, ImageProvider provider, Offset position,
  CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  ContextMenuController.removeAny();
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final copy = await showMenu<bool>(context: context,
    position: RelativeRect.fromRect(overlay.globalToLocal(position) & Size.zero, Offset.zero & overlay.size),
    items: [const PopupMenuItem(value: true, child: Text('Copy image'))]);
  if (copy != true || !context.mounted || cancellation.isCancelled) return;
  try {
    // Resolve the original provider, independently of thumbnail size or zoom.
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final ready = Completer<void>();
    ImageInfo? info;
    final listener = ImageStreamListener((image, _) {
      if (ready.isCompleted) { image.dispose(); return; }
      info = image;
      ready.complete();
    }, onError: (Object error, StackTrace? stack) {
      if (!ready.isCompleted) ready.completeError(error, stack);
    });
    stream.addListener(listener);
    try {
      await ready.future.asCancellable(cancellation);
      final png = await info!.image.toByteData(format: ui.ImageByteFormat.png);
      cancellation.throwIfCancelled();
      if (png == null) throw StateError('Could not encode the image');
      await writeClipboardImage(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), cancellation);
    } finally {
      stream.removeListener(listener);
      info?.dispose();
    }
  } on CancelledException {
    // Closing the image or its conversation cancels the pending copy.
  } catch (_) {
    if (context.mounted && !cancellation.isCancelled) {
      showDesktopToast(context, 'Could not copy image to the clipboard.', type: DesktopToastType.error);
    }
  }
}
