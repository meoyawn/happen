import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'app_icon.dart';
import 'native_app_icon_macos.dart';
import 'native_app_icon_windows.dart';

bool get supportsAppIconSwitching => Platform.isMacOS || Platform.isWindows;

const toiletPaperIconAsset =
  'macos/Runner/Assets.xcassets/AppIconToiletPaper.appiconset/app_icon_1024.png';

String appIconPreviewAsset(AppIconChoice choice) {
  if (choice == AppIconChoice.toiletPaper) return toiletPaperIconAsset;
  if (Platform.isMacOS) {
    return 'macos/Runner/Assets.xcassets/${kDebugMode ? 'AppIconDebug' : 'AppIcon'}.appiconset/app_icon_256.png';
  }
  return 'assets/app-icons/default-windows.png';
}

/// Native handles belong to this desktop session; only the choice is persisted.
class DesktopIconEffects {
  DesktopIconEffects(this.directory);
  final String directory;
  WindowsAppIcon? _windows;
  bool _macOverride = false;

  Future<void> apply(AppIconChoice choice, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    if (Platform.isMacOS) {
      if (choice == AppIconChoice.standard) {
        if (_macOverride) setMacOSAppIcon(null);
        _macOverride = false;
      } else {
        final image = await rootBundle.load(toiletPaperIconAsset).asCancellable(cancellation);
        cancellation.throwIfCancelled();
        setMacOSAppIcon(image.buffer.asUint8List(image.offsetInBytes, image.lengthInBytes));
        _macOverride = true;
      }
    } else if (Platform.isWindows) {
      if (choice == AppIconChoice.standard) {
        _windows?.restore();
      } else {
        final image = await rootBundle.load('assets/app-icons/toilet-paper.ico').asCancellable(cancellation);
        final cache = Directory('$directory/app-icons');
        await cache.create(recursive: true).asCancellable(cancellation);
        final file = File('${cache.path}/toilet-paper.ico');
        await file.writeAsBytes(image.buffer.asUint8List(image.offsetInBytes, image.lengthInBytes))
          .asCancellable(cancellation);
        cancellation.throwIfCancelled();
        (_windows ??= WindowsAppIcon()).set(file.path);
      }
    }
  }

  void close() {
    if (Platform.isMacOS && _macOverride) {
      setMacOSAppIcon(null);
      _macOverride = false;
    }
    _windows?.close();
    _windows = null;
  }
}
