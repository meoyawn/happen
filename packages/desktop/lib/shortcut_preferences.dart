import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:protocol/protocol.dart';

enum DesktopShortcut { promptHistory, machinePicker }

String _settingKey(DesktopShortcut command) => switch (command) {
  DesktopShortcut.promptHistory => 'prompt_history_shortcut',
  DesktopShortcut.machinePicker => 'machine_picker_shortcut',
};

SingleActivator? _defaultShortcut(DesktopShortcut command) => switch (command) {
  DesktopShortcut.promptHistory => null,
  DesktopShortcut.machinePicker => const SingleActivator(LogicalKeyboardKey.keyM, alt: true, includeRepeats: false),
};

const shortcutModifierKeys = [
  LogicalKeyboardKey.meta, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.control, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.alt, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.shift, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight,
];

bool sameShortcut(SingleActivator a, SingleActivator b) => a.trigger == b.trigger &&
  a.meta == b.meta && a.control == b.control && a.alt == b.alt && a.shift == b.shift;

String shortcutLabel(SingleActivator shortcut) {
  final mac = defaultTargetPlatform == TargetPlatform.macOS;
  final key = switch (shortcut.trigger) {
    LogicalKeyboardKey.arrowUp => '↑', LogicalKeyboardKey.arrowDown => '↓',
    LogicalKeyboardKey.arrowLeft => '←', LogicalKeyboardKey.arrowRight => '→',
    LogicalKeyboardKey.space => 'Space', LogicalKeyboardKey.enter => 'Enter',
    final key => key.keyLabel.toUpperCase(),
  };
  return [
    if (shortcut.control) mac ? '⌃' : 'Ctrl',
    if (shortcut.alt) mac ? '⌥' : 'Alt',
    if (shortcut.shift) mac ? '⇧' : 'Shift',
    if (shortcut.meta) mac ? '⌘' : 'Meta',
    key,
  ].join(' ');
}

String? shortcutInputError(SingleActivator shortcut) {
  if (shortcutModifierKeys.contains(shortcut.trigger) ||
      !shortcut.meta && !shortcut.control && !shortcut.alt) {
    return 'Use Command, Control, or Option with another key.';
  }
  return null;
}

String _encode(SingleActivator? shortcut) => shortcut == null ? '' : jsonEncode({
  'key': shortcut.trigger.keyId, 'meta': shortcut.meta, 'control': shortcut.control,
  'alt': shortcut.alt, 'shift': shortcut.shift,
});

SingleActivator? _decode(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    final saved = jsonDecode(value);
    if (saved is! Map<String, dynamic> || saved['key'] is! int) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(saved['key'] as int);
    if (key == null || shortcutModifierKeys.contains(key)) return null;
    final shortcut = SingleActivator(key, meta: saved['meta'] == true,
      control: saved['control'] == true, alt: saved['alt'] == true,
      shift: saved['shift'] == true, includeRepeats: false);
    return shortcutInputError(shortcut) == null ? shortcut : null;
  } on FormatException { return null; }
}

sealed class ShortcutState {
  const ShortcutState(this.value);
  final SingleActivator? value;
}

final class ShortcutLoading extends ShortcutState {
  const ShortcutLoading(super.value);
}

final class ShortcutReady extends ShortcutState {
  const ShortcutReady(super.value);
}

final class ShortcutSaving extends ShortcutState {
  const ShortcutSaving(super.value, this.pending);
  final SingleActivator? pending;
}

final class ShortcutFailed extends ShortcutState {
  const ShortcutFailed(super.value, this.error);
  final Object error;
}

final class ShortcutClosed extends ShortcutState {
  const ShortcutClosed(super.value);
}

ShortcutState _transition(ShortcutState current, ShortcutState next) =>
  switch ((current, next)) {
    (ShortcutLoading(), ShortcutReady() || ShortcutFailed()) => next,
    (ShortcutReady() || ShortcutFailed(), ShortcutSaving()) => next,
    (ShortcutSaving(), ShortcutReady() || ShortcutFailed()) => next,
    (_, ShortcutClosed()) when current is! ShortcutClosed => next,
    _ => throw StateError('Invalid shortcut transition'),
  };

class ShortcutController extends ChangeNotifier {
  ShortcutController(this.database, this.command) {
    _state = ShortcutLoading(_defaultShortcut(command));
    ready = _operation = _restore();
  }

  final IsolateOwner database;
  final DesktopShortcut command;
  final _lifetime = CancellationToken();
  late final Future<void> ready;
  Future<void>? _operation, _closing;
  late ShortcutState _state;
  ShortcutState get state => _state;

  void _set(ShortcutState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> _restore() async {
    try {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}, cancellation: _lifetime));
      _lifetime.throwIfCancelled();
      final value = saved['settings']?[_settingKey(command)] as String?;
      _set(ShortcutReady(value == null ? _defaultShortcut(command) : _decode(value)));
    } on CancelledException { /* Closing cancels the read. */ }
    catch (error) {
      if (!_lifetime.isCancelled) _set(ShortcutFailed(_state.value, error));
    }
  }

  Future<void> choose(SingleActivator? shortcut) {
    _lifetime.throwIfCancelled();
    if (_state is! ShortcutReady && _state is! ShortcutFailed) {
      throw StateError('Shortcut is still updating');
    }
    if (shortcut != null) {
      final error = shortcutInputError(shortcut);
      if (error != null) throw ArgumentError(error);
    }
    if (_state is ShortcutReady &&
        (shortcut == null && _state.value == null || shortcut != null && _state.value != null && sameShortcut(shortcut, _state.value!))) {
      return Future.value();
    }
    return _operation = _save(shortcut);
  }

  Future<void> _save(SingleActivator? shortcut) async {
    final previous = _state.value;
    _set(ShortcutSaving(previous, shortcut));
    try {
      await callIsolate(database.port, 'settings.set', {
        'key': _settingKey(command), 'value': _encode(shortcut),
      }, cancellation: _lifetime);
      _lifetime.throwIfCancelled();
      _set(ShortcutReady(shortcut));
    } on CancelledException { /* A closed owner ignores stale completion. */ }
    catch (error) {
      if (!_lifetime.isCancelled) _set(ShortcutFailed(previous, error));
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final pending = _state is ShortcutLoading || _state is ShortcutSaving ? _operation : null;
    _set(ShortcutClosed(_state.value));
    _lifetime.cancel();
    try { await pending; }
    catch (_) { /* The settings action reports write failures. */ }
    finally { dispose(); }
  }
}
