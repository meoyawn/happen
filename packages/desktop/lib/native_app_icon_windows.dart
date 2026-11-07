import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final _user = DynamicLibrary.open('user32.dll');
final _findWindow = _user.lookupFunction<
  Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>),
  Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _windowProcess = _user.lookupFunction<Uint32 Function(Pointer<Void>, Pointer<Uint32>),
  int Function(Pointer<Void>, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _isWindow = _user.lookupFunction<Int32 Function(Pointer<Void>),
  int Function(Pointer<Void>)>('IsWindow');
final _message = _user.lookupFunction<IntPtr Function(Pointer<Void>, Uint32, UintPtr, IntPtr),
  int Function(Pointer<Void>, int, int, int)>('SendMessageW');
final _loadImage = _user.lookupFunction<
  Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>, Uint32, Int32, Int32, Uint32),
  Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>, int, int, int, int)>('LoadImageW');
final _destroyIcon = _user.lookupFunction<Int32 Function(Pointer<Void>),
  int Function(Pointer<Void>)>('DestroyIcon');
final _metric = _user.lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');

const _getIcon = 0x007f, _setIcon = 0x0080, _big = 1, _small = 0;

Pointer<Void> _ownWindow() => using((arena) {
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena);
  final process = arena<Uint32>();
  var after = nullptr.cast<Void>();
  while (true) {
    after = _findWindow(nullptr, after, className, nullptr);
    if (after == nullptr) throw StateError('Could not find the Happen window');
    if (_windowProcess(after, process) != 0 && process.value == pid) return after;
  }
});

/// Own only loaded HICONs; the original runner icons are borrowed and never destroyed.
class WindowsAppIcon {
  WindowsAppIcon() : _window = _ownWindow() {
    _originalBig = _message(_window, _getIcon, _big, 0);
    _originalSmall = _message(_window, _getIcon, _small, 0);
  }

  final Pointer<Void> _window;
  late final int _originalBig, _originalSmall;
  Pointer<Void> _bigIcon = nullptr, _smallIcon = nullptr;

  void set(String path) => using((arena) {
    if (_isWindow(_window) == 0) throw StateError('The Happen window is unavailable');
    final name = path.toNativeUtf16(allocator: arena);
    // IMAGE_ICON, LR_LOADFROMFILE. Both handles are private, not LR_SHARED.
    final big = _loadImage(nullptr, name, 1, 256, 256, 0x10);
    if (big == nullptr) throw StateError('Could not load the app icon');
    final small = _loadImage(nullptr, name, 1, _metric(49), _metric(50), 0x10);
    if (small == nullptr) {
      _destroyIcon(big);
      throw StateError('Could not load the small app icon');
    }
    _message(_window, _setIcon, _big, big.address);
    _message(_window, _setIcon, _small, small.address);
    _destroyOwned();
    _bigIcon = big;
    _smallIcon = small;
  });

  void restore() {
    if (_isWindow(_window) != 0) {
      _message(_window, _setIcon, _big, _originalBig);
      _message(_window, _setIcon, _small, _originalSmall);
    }
    _destroyOwned();
  }

  void _destroyOwned() {
    if (_bigIcon != nullptr) _destroyIcon(_bigIcon);
    if (_smallIcon != nullptr) _destroyIcon(_smallIcon);
    _bigIcon = _smallIcon = nullptr;
  }

  void close() => restore();
}
