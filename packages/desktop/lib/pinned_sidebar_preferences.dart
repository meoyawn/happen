import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';

enum PinnedThreadLayout { byProject, flat }

typedef PinnedSidebarPreferences = ({PinnedThreadLayout layout, Set<String> collapsedProjects});

const _defaults = (layout: PinnedThreadLayout.byProject, collapsedProjects: <String>{});

sealed class PinnedSidebarState {
  const PinnedSidebarState(this.value);
  final PinnedSidebarPreferences value;
}

final class PinnedSidebarLoading extends PinnedSidebarState {
  const PinnedSidebarLoading() : super(_defaults);
}

final class PinnedSidebarReady extends PinnedSidebarState {
  const PinnedSidebarReady(super.value);
}

final class PinnedSidebarSaving extends PinnedSidebarState {
  const PinnedSidebarSaving(this.previous, PinnedSidebarPreferences pending) : super(pending);
  final PinnedSidebarPreferences previous;
}

final class PinnedSidebarFailed extends PinnedSidebarState {
  const PinnedSidebarFailed(super.value, this.error);
  final Object error;
}

final class PinnedSidebarClosed extends PinnedSidebarState {
  const PinnedSidebarClosed(super.value);
}

PinnedSidebarState _transition(PinnedSidebarState current, PinnedSidebarState next) => switch ((current, next)) {
  (PinnedSidebarLoading(), PinnedSidebarReady() || PinnedSidebarFailed()) => next,
  (PinnedSidebarReady() || PinnedSidebarFailed(), PinnedSidebarSaving()) => next,
  (PinnedSidebarSaving(), PinnedSidebarReady() || PinnedSidebarFailed()) => next,
  (PinnedSidebarLoading() || PinnedSidebarReady() || PinnedSidebarSaving() || PinnedSidebarFailed(),
    PinnedSidebarClosed()) => next,
  _ => throw StateError('Invalid pinned sidebar transition'),
};

PinnedSidebarPreferences _decode(Object? saved) {
  if (saved is! String) return _defaults;
  try {
    final value = jsonDecode(saved);
    if (value is! Map) return _defaults;
    return (
      layout: value['layout'] == 'flat' ? PinnedThreadLayout.flat : PinnedThreadLayout.byProject,
      collapsedProjects: Set.unmodifiable(switch (value['collapsedProjects']) {
        final List<Object?> projects => projects.whereType<String>(),
        _ => const <String>[],
      }),
    );
  } on FormatException {
    return _defaults;
  }
}

/// Shared by local and remote sessions; only the desktop database owns these preferences.
class PinnedSidebarController extends ChangeNotifier {
  PinnedSidebarController(this.database) {
    ready = _operation = _restore();
  }

  final IsolateOwner database;
  final _lifetime = CancellationToken();
  late final Future<void> ready;
  Future<void>? _operation, _closing;
  PinnedSidebarState _state = const PinnedSidebarLoading();
  PinnedSidebarState get state => _state;
  PinnedSidebarPreferences get value => _state.value;
  bool get enabled => _state is PinnedSidebarReady || _state is PinnedSidebarFailed;

  void _set(PinnedSidebarState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> _restore() async {
    try {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}, cancellation: _lifetime));
      _lifetime.throwIfCancelled();
      _set(PinnedSidebarReady(_decode(saved['settings']?['sidebar_pinned_view'])));
    } on CancelledException {
      // Closing cancels the read and ignores its completion.
    } catch (error) {
      if (!_lifetime.isCancelled) _set(PinnedSidebarFailed(_defaults, error));
    }
  }

  Future<void> chooseLayout(PinnedThreadLayout layout) =>
    _choose((layout: layout, collapsedProjects: value.collapsedProjects));

  Future<void> chooseCollapsed(String project, bool collapsed) => _choose((
    layout: value.layout,
    collapsedProjects: Set.unmodifiable({
      for (final id in value.collapsedProjects) if (id != project) id,
      if (collapsed) project,
    }),
  ));

  Future<void> _choose(PinnedSidebarPreferences next) {
    _lifetime.throwIfCancelled();
    if (!enabled) throw StateError('Pinned sidebar is still updating');
    if (value.layout == next.layout && setEquals(value.collapsedProjects, next.collapsedProjects)) return Future.value();
    return _operation = _save(next);
  }

  Future<void> _save(PinnedSidebarPreferences next) async {
    final previous = value;
    _set(PinnedSidebarSaving(previous, next));
    try {
      await callIsolate(database.port, 'settings.set', {
        'key': 'sidebar_pinned_view',
        'value': jsonEncode({'layout': next.layout.name, 'collapsedProjects': next.collapsedProjects.toList()}),
      }, cancellation: _lifetime);
      _lifetime.throwIfCancelled();
      _set(PinnedSidebarReady(next));
    } on CancelledException {
      // The closed owner ignores even a committed completion.
    } catch (error) {
      if (!_lifetime.isCancelled) _set(PinnedSidebarFailed(previous, error));
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final pending = _state is PinnedSidebarLoading || _state is PinnedSidebarSaving ? _operation : null;
    _set(PinnedSidebarClosed(value));
    _lifetime.cancel();
    try {
      await pending;
    } catch (_) {
      // The settings action has already reported the failure.
    } finally {
      dispose();
    }
  }
}
