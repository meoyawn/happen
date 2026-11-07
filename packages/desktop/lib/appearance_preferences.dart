import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';

sealed class AppearanceState {
  const AppearanceState(this.value);
  final Color value;
}

final class AppearanceLoading extends AppearanceState {
  const AppearanceLoading() : super(desktopDefaultAccent);
}

final class AppearanceReady extends AppearanceState {
  const AppearanceReady(super.value);
}

final class AppearanceSaving extends AppearanceState {
  const AppearanceSaving(super.value, this.pending);
  final Color pending;
}

final class AppearanceFailed extends AppearanceState {
  const AppearanceFailed(super.value, this.error);
  final Object error;
}

final class AppearanceClosed extends AppearanceState {
  const AppearanceClosed(super.value);
}

AppearanceState _transition(AppearanceState current, AppearanceState next) => switch ((current, next)) {
  (AppearanceLoading(), AppearanceReady() || AppearanceFailed()) => next,
  (AppearanceReady() || AppearanceFailed(), AppearanceSaving()) => next,
  (AppearanceSaving(), AppearanceReady() || AppearanceFailed()) => next,
  (AppearanceLoading() || AppearanceReady() || AppearanceSaving() || AppearanceFailed(), AppearanceClosed()) => next,
  _ => throw StateError('Invalid appearance transition'),
};

/// Owns the durable accent. Theme consumers only see a new color after commit.
class AppearanceController extends ChangeNotifier {
  AppearanceController(this.database) {
    ready = _operation = _restore();
  }

  final IsolateOwner database;
  final _lifetime = CancellationToken();
  late final Future<void> ready;
  Future<void>? _operation, _closing;
  AppearanceState _state = const AppearanceLoading();
  AppearanceState get state => _state;

  void _set(AppearanceState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> _restore() async {
    try {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}, cancellation: _lifetime));
      _lifetime.throwIfCancelled();
      final value = saved['settings']?['accent_color'] as String?;
      _set(AppearanceReady(value == null ? desktopDefaultAccent : parseDesktopAccent(value) ?? desktopDefaultAccent));
    } on CancelledException {
      // Session close cancels the read and drains it before disposing.
    } catch (error) {
      if (!_lifetime.isCancelled) _set(AppearanceFailed(desktopDefaultAccent, error));
    }
  }

  Future<void> choose(Color value) {
    _lifetime.throwIfCancelled();
    if (_state is AppearanceLoading || _state is AppearanceSaving) {
      throw StateError('Appearance is still updating');
    }
    if (_state is AppearanceReady && _state.value == value) return Future.value();
    return _operation = _save(value);
  }

  Future<void> _save(Color value) async {
    final previous = _state.value;
    _set(AppearanceSaving(previous, value));
    try {
      await callIsolate(database.port, 'settings.set', {
        'key': 'accent_color', 'value': desktopAccentHex(value),
      }, cancellation: _lifetime);
      _lifetime.throwIfCancelled();
      _set(AppearanceReady(value));
    } on CancelledException {
      // A closed owner ignores the completion, including a committed write.
    } catch (error) {
      if (!_lifetime.isCancelled) _set(AppearanceFailed(previous, error));
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _set(AppearanceClosed(_state.value));
    _lifetime.cancel();
    try {
      await _operation;
    } catch (_) {
      // The settings action has already reported its failure.
    } finally {
      dispose();
    }
  }
}
