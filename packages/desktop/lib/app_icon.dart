import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';

enum AppIconChoice {
  standard('default', 'Default'),
  toiletPaper('toilet-paper', 'Toilet paper');

  const AppIconChoice(this.id, this.label);
  final String id, label;

  static AppIconChoice fromSetting(Object? value) =>
    values.where((choice) => choice.id == value).firstOrNull ?? standard;
}

sealed class AppIconState {
  const AppIconState(this.value);
  final AppIconChoice value;
}

final class AppIconLoading extends AppIconState {
  const AppIconLoading() : super(AppIconChoice.standard);
}

final class AppIconReady extends AppIconState {
  const AppIconReady(super.value);
}

final class AppIconSaving extends AppIconState {
  const AppIconSaving(super.value, this.pending);
  final AppIconChoice pending;
}

final class AppIconFailed extends AppIconState {
  const AppIconFailed(super.value, this.error);
  final Object error;
}

final class AppIconClosed extends AppIconState {
  const AppIconClosed(super.value);
}

AppIconState _transition(AppIconState current, AppIconState next) => switch ((current, next)) {
  (AppIconLoading(), AppIconReady() || AppIconFailed()) => next,
  (AppIconReady() || AppIconFailed(), AppIconSaving()) => next,
  (AppIconSaving(), AppIconReady() || AppIconFailed()) => next,
  (AppIconLoading() || AppIconReady() || AppIconSaving() || AppIconFailed(), AppIconClosed()) => next,
  _ => throw StateError('Invalid app icon transition'),
};

/// A device preference is confirmed only after its native effect and SQLite commit.
class AppIconController extends ChangeNotifier {
  AppIconController(this.database, {required this.apply, required this.release}) {
    ready = _operation = _restore();
  }

  final IsolateOwner database;
  final Future<void> Function(AppIconChoice, CancellationToken) apply;
  final void Function() release;
  final _lifetime = CancellationToken();
  late final Future<void> ready;
  Future<void>? _operation, _closing;
  AppIconState _state = const AppIconLoading();
  AppIconState get state => _state;

  void _set(AppIconState next) {
    if (_state is AppIconClosed) return;
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> _restore() async {
    var value = AppIconChoice.standard;
    try {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}, cancellation: _lifetime));
      value = AppIconChoice.fromSetting(saved['settings']?['app_icon']);
      await apply(value, _lifetime);
      _lifetime.throwIfCancelled();
      _set(AppIconReady(value));
    } on CancelledException {
      // The owning desktop session closed.
    } catch (error) {
      _set(AppIconFailed(value, error));
    }
  }

  Future<void> choose(AppIconChoice value) {
    _lifetime.throwIfCancelled();
    if (_state is AppIconLoading || _state is AppIconSaving) {
      throw StateError('The app icon is still updating');
    }
    if (_state is AppIconReady && _state.value == value) return Future.value();
    return _operation = _save(value);
  }

  Future<void> _save(AppIconChoice value) async {
    final previous = _state.value;
    _set(AppIconSaving(previous, value));
    var applied = false;
    try {
      await apply(value, _lifetime);
      applied = true;
      _lifetime.throwIfCancelled();
      await callIsolate(database.port, 'settings.set', {'key': 'app_icon', 'value': value.id},
        cancellation: _lifetime);
      _lifetime.throwIfCancelled();
      _set(AppIconReady(value));
    } on CancelledException {
      // Close drains this operation before releasing native resources.
    } catch (error) {
      if (applied && !_lifetime.isCancelled) {
        try {
          await apply(previous, _lifetime);
        } catch (rollback) {
          _set(AppIconFailed(previous, '$error\nCould not restore the previous icon: $rollback'));
          rethrow;
        }
      }
      _set(AppIconFailed(previous, error));
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _set(AppIconClosed(_state.value));
    _lifetime.cancel();
    try {
      await _operation;
    } catch (_) {
      // A failed user action has already been reported by its caller.
    } finally {
      try { release(); } finally { dispose(); }
    }
  }
}
