import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:protocol/protocol.dart';

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

sealed class PromptHistoryShortcutState {
  const PromptHistoryShortcutState(this.value);
  final SingleActivator? value;
}

final class PromptHistoryShortcutLoading extends PromptHistoryShortcutState {
  const PromptHistoryShortcutLoading() : super(null);
}

final class PromptHistoryShortcutReady extends PromptHistoryShortcutState {
  const PromptHistoryShortcutReady(super.value);
}

final class PromptHistoryShortcutSaving extends PromptHistoryShortcutState {
  const PromptHistoryShortcutSaving(super.value, this.pending);
  final SingleActivator? pending;
}

final class PromptHistoryShortcutFailed extends PromptHistoryShortcutState {
  const PromptHistoryShortcutFailed(super.value, this.error);
  final Object error;
}

final class PromptHistoryShortcutClosed extends PromptHistoryShortcutState {
  const PromptHistoryShortcutClosed(super.value);
}

PromptHistoryShortcutState _transition(PromptHistoryShortcutState current, PromptHistoryShortcutState next) =>
  switch ((current, next)) {
    (PromptHistoryShortcutLoading(), PromptHistoryShortcutReady() || PromptHistoryShortcutFailed()) => next,
    (PromptHistoryShortcutReady() || PromptHistoryShortcutFailed(), PromptHistoryShortcutSaving()) => next,
    (PromptHistoryShortcutSaving(), PromptHistoryShortcutReady() || PromptHistoryShortcutFailed()) => next,
    (_, PromptHistoryShortcutClosed()) when current is! PromptHistoryShortcutClosed => next,
    _ => throw StateError('Invalid prompt history shortcut transition'),
  };

class PromptHistoryShortcutController extends ChangeNotifier {
  PromptHistoryShortcutController(this.database) {
    ready = _operation = _restore();
  }

  final IsolateOwner database;
  final _lifetime = CancellationToken();
  late final Future<void> ready;
  Future<void>? _operation, _closing;
  PromptHistoryShortcutState _state = const PromptHistoryShortcutLoading();
  PromptHistoryShortcutState get state => _state;

  void _set(PromptHistoryShortcutState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> _restore() async {
    try {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}, cancellation: _lifetime));
      _lifetime.throwIfCancelled();
      _set(PromptHistoryShortcutReady(_decode(saved['settings']?['prompt_history_shortcut'] as String?)));
    } on CancelledException { /* Closing cancels the read. */ }
    catch (error) {
      if (!_lifetime.isCancelled) _set(PromptHistoryShortcutFailed(null, error));
    }
  }

  Future<void> choose(SingleActivator? shortcut) {
    _lifetime.throwIfCancelled();
    if (_state is! PromptHistoryShortcutReady && _state is! PromptHistoryShortcutFailed) {
      throw StateError('Prompt history shortcut is still updating');
    }
    if (shortcut != null) {
      final error = shortcutInputError(shortcut);
      if (error != null) throw ArgumentError(error);
    }
    if (_state is PromptHistoryShortcutReady &&
        (shortcut == null && _state.value == null || shortcut != null && _state.value != null && sameShortcut(shortcut, _state.value!))) {
      return Future.value();
    }
    return _operation = _save(shortcut);
  }

  Future<void> _save(SingleActivator? shortcut) async {
    final previous = _state.value;
    _set(PromptHistoryShortcutSaving(previous, shortcut));
    try {
      await callIsolate(database.port, 'settings.set', {
        'key': 'prompt_history_shortcut', 'value': _encode(shortcut),
      }, cancellation: _lifetime);
      _lifetime.throwIfCancelled();
      _set(PromptHistoryShortcutReady(shortcut));
    } on CancelledException { /* A closed owner ignores stale completion. */ }
    catch (error) {
      if (!_lifetime.isCancelled) _set(PromptHistoryShortcutFailed(previous, error));
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final pending = _state is PromptHistoryShortcutLoading || _state is PromptHistoryShortcutSaving ? _operation : null;
    _set(PromptHistoryShortcutClosed(_state.value));
    _lifetime.cancel();
    try { await pending; }
    catch (_) { /* The settings action reports write failures. */ }
    finally { dispose(); }
  }
}
