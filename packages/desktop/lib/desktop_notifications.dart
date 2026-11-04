import 'dart:async';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:protocol/protocol.dart';

import 'desktop_toast.dart';
import 'notification_preferences.dart';
import 'panel_state.dart';
import 'session.dart';

Future<bool> requestDesktopNotificationPermission({required CancellationToken cancellation}) async {
  final macOS = FlutterLocalNotificationsPlugin()
    .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
  if (macOS == null) return true;
  return await macOS.requestPermissions(alert: true, badge: true)
    .asCancellable(cancellation) == true;
}

/// Lives beside the desktop session until process shutdown, independently of its window.
class DesktopNotifications {
  DesktopNotifications(this.session) {
    _events = session.notifications.listen(_present);
    session.addListener(_synchronize);
    _lifecycle = AppLifecycleListener(onResume: () {
      if (_focused) _clearPending();
    });
    _synchronize();
  }

  final DesktopSession session;
  final _plugin = FlutterLocalNotificationsPlugin();
  final _lifetime = CancellationToken();
  final _requestedTask = ValueNotifier<DesktopTask?>(null);
  final _pending = <String, ({int id, TaskNotificationKind kind})>{};
  final _toasts = <String, ({VoidCallback dismiss, TaskNotificationKind kind})>{};
  final _sounds = <bool, AudioPlayer>{};
  final _startingSounds = <bool>{};
  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<TaskNotification> _events;
  _DesktopNotificationWindowState? _window;
  Future<void>? _initializing;
  Future<void>? _closing;
  Future<void> _nativeWork = Future.value();
  String? _mode;

  bool get _focused => _window != null && (WidgetsBinding.instance.lifecycleState == null ||
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  bool get _desktop => {TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.windows}.contains(defaultTargetPlatform);

  void _attach(_DesktopNotificationWindowState window) {
    if (_lifetime.isCancelled) return;
    _clearToasts();
    _window = window;
    if (_focused) _clearPending();
  }

  void _detach(_DesktopNotificationWindowState window) {
    if (_window != window) return;
    _window = null;
    _clearToasts();
  }

  Future<void> _attempt(Future<void> Function() operation) async {
    try {
      await operation();
    } on CancelledException {
      // Desktop process shutdown owns cancellation.
    } on MissingPluginException {
      // A native plugin added during hot reload becomes available on relaunch.
    } catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack, library: 'desktop notifications'));
    }
  }

  void _run(Future<void> Function() operation) => unawaited(_attempt(operation));

  void _enqueue(Future<void> Function() operation) {
    _nativeWork = _nativeWork.then((_) => _attempt(() async {
      if (!_lifetime.isCancelled) await operation();
    }));
  }

  Future<void> _initialize() => _initializing ??= () async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false, requestSoundPermission: false, requestBadgePermission: false,
            defaultPresentSound: false, defaultPresentAlert: false, defaultPresentBanner: false, defaultPresentList: false),
          linux: LinuxInitializationSettings(defaultActionName: 'Open chat'),
          windows: WindowsInitializationSettings(appName: 'Happen', appUserModelId: 'Happen.Desktop',
            guid: '16c9bf4c-61b7-4b3f-870a-4060e5d70c29'),
        ),
        onDidReceiveNotificationResponse: (response) {
          if (response.notificationResponseType == NotificationResponseType.selectedNotification) {
            _open(response.payload, activate: true);
          }
        },
      ).asCancellable(_lifetime);
      final launch = await _plugin.getNotificationAppLaunchDetails().asCancellable(_lifetime);
      if (launch?.didNotificationLaunchApp == true) {
        _open(launch?.notificationResponse?.payload, activate: true);
      }
      await _badge();
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }();

  Iterable<DesktopTask> get _tasks sync* {
    for (final project in session.projects) {
      if (!project.removing) yield* project.tasks;
    }
    for (final side in session.sideChats.values) {
      if (session.projects.any((project) => !project.removing && project.tasks.any((task) =>
          task.id == side.sideParentID && !task.archived && !task.archiving))) { yield side; }
    }
  }

  void _synchronize() {
    if (_mode != session.notificationMode) {
      _mode = session.notificationMode;
      _clearPending();
      if (_desktop && hasSystemNotifications(_mode!)) _enqueue(_initialize);
      if (!hasNotificationSound(_mode!)) {
        for (final player in _sounds.values) { _run(() => player.stop().asCancellable(_lifetime)); }
      }
    }
    final visible = {for (final task in _tasks) if (!task.archived && !task.archiving) task.id: task};
    bool keep(String id, TaskNotificationKind kind) => visible.containsKey(id) &&
      (kind != TaskNotificationKind.input || visible[id]!.questions.isNotEmpty);
    for (final entry in _pending.entries.toList()) {
      if (keep(entry.key, entry.value.kind)) continue;
      _pending.remove(entry.key);
      _enqueue(() async {
        await _plugin.cancel(id: entry.value.id).asCancellable(_lifetime);
        await _badge();
      });
    }
    for (final entry in _toasts.entries.toList()) {
      if (session.inAppNotificationsEnabled && keep(entry.key, entry.value.kind) &&
          _window?._isViewing(visible[entry.key]!) != true) { continue; }
      _toasts.remove(entry.key)?.dismiss();
    }
  }

  void _present(TaskNotification notification) {
    final (:task, :kind) = notification;
    if (_lifetime.isCancelled || task.archived || task.archiving || !_tasks.contains(task) ||
        kind == TaskNotificationKind.input && task.questions.isEmpty) { return; }
    final title = switch (kind) {
      TaskNotificationKind.input => 'Input needed',
      TaskNotificationKind.completion => 'Chat completed',
      TaskNotificationKind.failure => 'Chat failed',
    };
    if (hasNotificationSound(session.notificationMode) && _desktop) _playSound(kind);
    if (_focused) {
      if (!session.inAppNotificationsEnabled || _window!._isViewing(task)) return;
      _toasts.remove(task.id)?.dismiss();
      final dismiss = _window!._showToast(notification, title);
      if (dismiss != null) _toasts[task.id] = (dismiss: dismiss, kind: kind);
      return;
    }
    if (!_desktop || !hasSystemNotifications(session.notificationMode)) return;
    _enqueue(() async {
      await _initialize();
      if (_focused || task.archived || task.archiving || !_tasks.contains(task) ||
          !hasSystemNotifications(session.notificationMode) ||
          kind == TaskNotificationKind.input && task.questions.isEmpty) { return; }
      final id = _notificationId(task.id);
      // Track before the native call so process shutdown can cancel an in-flight alert.
      _pending[task.id] = (id: id, kind: kind);
      await _plugin.show(id: id, title: title, body: task.title, payload: task.id,
        notificationDetails: NotificationDetails(
          macOS: DarwinNotificationDetails(presentSound: false, threadIdentifier: task.id),
          linux: const LinuxNotificationDetails(suppressSound: true),
          windows: WindowsNotificationDetails(audio: WindowsNotificationAudio.silent()),
        )).asCancellable(_lifetime);
      await _badge();
    });
  }

  void _playSound(TaskNotificationKind kind) {
    final completion = kind == TaskNotificationKind.completion;
    if (_startingSounds.contains(completion) || _sounds[completion]?.state == PlayerState.playing) return;
    _startingSounds.add(completion);
    _run(() async {
      try {
        final player = _sounds.putIfAbsent(completion, AudioPlayer.new);
        await player.play(AssetSource('notifications/${completion ? 'completion' : 'input'}.mp3'))
          .asCancellable(_lifetime);
        if (!hasNotificationSound(session.notificationMode)) await player.stop().asCancellable(_lifetime);
      } finally {
        _startingSounds.remove(completion);
      }
    });
  }

  void _open(String? id, {bool activate = false}) {
    if (_lifetime.isCancelled || id == null) return;
    final task = _tasks.where((task) => task.id == id && !task.archived && !task.archiving).firstOrNull;
    if (task == null) return;
    _toasts.remove(id)?.dismiss();
    _requestedTask.value = task;
    if (activate && {TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform)) {
      _run(() => const MethodChannel('happen/desktop').invokeMethod<void>('activate').asCancellable(_lifetime));
    }
    _clearPending();
  }

  DesktopTask? _takeRequestedTask() {
    if (_lifetime.isCancelled) return null;
    final id = _requestedTask.value?.id;
    _requestedTask.value = null;
    return _tasks.where((task) => task.id == id && !task.archived && !task.archiving).firstOrNull;
  }

  Future<void> _badge() async {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await AppBadgePlus.updateBadge(_pending.length).asCancellable(_lifetime);
    }
  }

  void _clearPending() {
    _enqueue(() async {
      final ids = _pending.values.map((entry) => entry.id).toList();
      _pending.clear();
      for (final id in ids) { await _plugin.cancel(id: id).asCancellable(_lifetime); }
      if (_initializing != null || ids.isNotEmpty) await _badge();
    });
  }

  void _clearToasts() {
    for (final toast in _toasts.values) { toast.dismiss(); }
    _toasts.clear();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    session.removeListener(_synchronize);
    _lifecycle.dispose();
    _lifetime.cancel();
    _window = null;
    _clearToasts();
    _requestedTask.dispose();
    await _events.cancel();
    await _nativeWork;
    await Future.wait([for (final player in _sounds.values) _attempt(player.dispose)]);
    final ids = _pending.values.map((entry) => entry.id).toList();
    _pending.clear();
    for (final id in ids) { await _attempt(() => _plugin.cancel(id: id)); }
    if (defaultTargetPlatform == TargetPlatform.macOS && (_initializing != null || ids.isNotEmpty)) {
      await _attempt(() => AppBadgePlus.updateBadge(0));
    }
  }
}

/// Attaches window presentation and navigation without owning native notifications.
class DesktopNotificationWindow extends StatefulWidget {
  const DesktopNotificationWindow({super.key, required this.notifications, required this.onOpen, required this.child});
  final DesktopNotifications notifications;
  final ValueChanged<DesktopTask> onOpen;
  final Widget child;

  @override
  State<DesktopNotificationWindow> createState() => _DesktopNotificationWindowState();
}

class _DesktopNotificationWindowState extends State<DesktopNotificationWindow> {
  bool _openingScheduled = false;
  DesktopNotifications get notifications => widget.notifications;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    notifications._attach(this);
    notifications._requestedTask.addListener(_openRequestedTask);
    _openRequestedTask();
  }

  void _detach(DesktopNotifications owner) {
    owner._requestedTask.removeListener(_openRequestedTask);
    owner._detach(this);
  }

  @override
  void didUpdateWidget(DesktopNotificationWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notifications == notifications) return;
    _detach(oldWidget.notifications);
    _attach();
  }

  void _openRequestedTask() {
    if (_openingScheduled || notifications._requestedTask.value == null) return;
    _openingScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openingScheduled = false;
      if (!mounted || notifications._window != this) return;
      final task = notifications._takeRequestedTask();
      if (task != null) widget.onOpen(task);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _isViewing(DesktopTask task) {
    final session = notifications.session;
    if (!session.viewingConversation || ModalRoute.of(context)?.isCurrent == false) return false;
    if (session.task == task) return true;
    if (task.sideParentID != session.task?.id) return false;
    final panels = session.panelLayouts[task.sideParentID];
    return panels?.opened == true && panels?.active == sideChatPanel(task.id);
  }

  VoidCallback? _showToast(TaskNotification notification, String title) =>
    showDesktopToast(context, title, tag: 'chat:${notification.task.id}', description: notification.task.title,
      icon: switch (notification.kind) {
        TaskNotificationKind.input => Icons.question_answer_outlined,
        TaskNotificationKind.completion => Icons.check_circle_outline,
        TaskNotificationKind.failure => Icons.error_outline,
      },
      actionLabel: 'Open chat', onAction: () => notifications._open(notification.task.id));

  @override
  void dispose() {
    _detach(notifications);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

int _notificationId(String id) {
  var hash = 0x811c9dc5;
  for (final unit in id.codeUnits) { hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff; }
  return hash;
}
