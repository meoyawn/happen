import 'dart:async';

import 'package:desktop/desktop_notifications.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('process alerts survive window detachment and open the right chat after reattachment', (tester) async {
    MacOSFlutterLocalNotificationsPlugin.registerWith();
    final client = _Client();
    final session = DesktopSession(client, _Database())
      ..notificationMode = 'notifications'
      ..inAppNotificationsEnabled = true;
    addTearDown(session.close);
    final current = DesktopTask('current', 'Current chat');
    final other = DesktopTask('other', 'Another chat');
    session.projects.add(Project('project', '/project', '/project', [current, other]));
    session.task = current;
    session.viewedTasks[current.id] = 0;
    final calls = <MethodCall>[];
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    const badge = MethodChannel('app_badge_plus');
    const desktop = MethodChannel('happen/desktop');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'initialize' ? true : null;
    });
    messenger.setMockMethodCallHandler(badge, (call) async { calls.add(call); return null; });
    messenger.setMockMethodCallHandler(desktop, (call) async { calls.add(call); return null; });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(badge, null);
      messenger.setMockMethodCallHandler(desktop, null);
    });
    final opened = <DesktopTask>[];
    final notifications = DesktopNotifications(session);
    addTearDown(notifications.close);
    Widget window() => MaterialApp(home: DesktopNotificationWindow(notifications: notifications,
      onOpen: opened.add, child: const Scaffold(body: Text('Workspace'))));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(window());
    await tester.pumpAndSettle();
    List<MethodCall> shown() => calls.where((call) => call.method == 'show').toList();
    void event(DesktopTask task, String id, String type, [Json data = const {}]) => client.events.add({
      'id': 'evt_$id', 'type': 'session.$type', 'created': 0,
      'data': {'sessionID': task.id, ...data},
    });
    void ask(DesktopTask task, String id) => event(task, id, 'question.asked', {
      'request': {'id': id, 'questions': []},
    });
    Future<void> clickNotification(int id, String taskID) async {
      final response = Completer<void>();
      tester.binding.channelBuffers.push(channel.name, const StandardMethodCodec().encodeMethodCall(
        MethodCall('didReceiveNotificationResponse', {
          'notificationResponseType': 0, 'notificationId': id, 'payload': taskID,
        })), (_) => response.complete());
      await tester.pumpAndSettle();
      await response.future;
    }
    expect(shown(), isEmpty);
    ask(current, 'current-question');
    await tester.pumpAndSettle();
    expect(find.text('Input needed'), findsNothing, reason: 'The focused chat already shows its question');
    ask(other, 'foreground-question');
    ask(other, 'foreground-question');
    await tester.pumpAndSettle();
    expect(find.text('Input needed'), findsOneWidget);
    expect(shown(), isEmpty);
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();
    expect(opened, [other]);
    expect(find.text('Input needed'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    ask(other, 'background-question');
    ask(other, 'background-question');
    await tester.pumpAndSettle();
    expect(shown(), hasLength(1));
    expect(shown().single.arguments['title'], 'Input needed');
    expect(shown().single.arguments['body'], 'Another chat');
    expect(shown().single.arguments['payload'], 'other');
    expect(shown().single.arguments['platformSpecifics']['presentSound'], false);
    expect(calls.lastWhere((call) => call.method == 'updateBadge').arguments['count'], 1);
    final notificationID = shown().single.arguments['id'];
    event(other, 'complete', 'execution.succeeded');
    event(other, 'complete', 'execution.succeeded');
    await tester.pumpAndSettle();
    expect(shown().map((call) => call.arguments['title']), ['Input needed', 'Chat completed']);
    expect(shown().last.arguments['id'], notificationID, reason: 'A chat replaces its previous system alert');
    expect(calls.lastWhere((call) => call.method == 'updateBadge').arguments['count'], 1);

    await clickNotification(notificationID, other.id);
    expect(opened, [other, other]);
    expect(calls.where((call) => call.method == 'activate'), hasLength(1));
    expect(calls.lastWhere((call) => call.method == 'updateBadge').arguments['count'], 0);
    expect(calls.where((call) => call.method == 'cancel').last.arguments, notificationID);

    event(other, 'failed', 'execution.failed', {'error': {'message': 'Provider unavailable'}});
    await tester.pumpAndSettle();
    expect(shown().last.arguments['title'], 'Chat failed');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls.lastWhere((call) => call.method == 'updateBadge').arguments['count'], 0);

    await tester.pumpWidget(const SizedBox.shrink());
    ask(other, 'windowless-question');
    await tester.pumpAndSettle();
    expect(shown(), hasLength(4), reason: 'Native alerts belong to the process even without an attached window');
    expect(shown().last.arguments['title'], 'Input needed');
    expect(calls.lastWhere((call) => call.method == 'updateBadge').arguments['count'], 1);
    await clickNotification(notificationID, other.id);
    expect(opened, [other, other], reason: 'Navigation waits for a window to attach');
    expect(calls.where((call) => call.method == 'activate'), hasLength(2));
    await tester.pumpWidget(window());
    await tester.pumpAndSettle();
    expect(opened, [other, other, other]);
    expect(calls.where((call) => call.method == 'initialize'), hasLength(1),
      reason: 'Recreating the window retains the native notification owner');
    expect(calls.lastWhere((call) => call.method == 'updateBadge').arguments['count'], 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    other.running = true;
    final stopping = session.stop(target: other);
    await tester.pump();
    await stopping;
    // A completion can already be in flight when the user requests Stop.
    event(other, 'stopped-completion', 'execution.succeeded');
    event(other, 'stopped', 'execution.interrupted', {'reason': 'user'});
    other.archived = true;
    event(other, 'archived', 'execution.succeeded');
    await tester.pumpAndSettle();
    expect(shown(), hasLength(4), reason: 'Stopped and archived work stays quiet');
    ask(current, 'shutdown-question');
    await tester.pumpAndSettle();
    expect(shown(), hasLength(5));
    expect(calls.lastWhere((call) => call.method == 'updateBadge').arguments['count'], 1);
    await notifications.close();
    expect(calls.where((call) => call.method == 'cancel').last.arguments, shown().last.arguments['id']);
    expect(calls.lastWhere((call) => call.method == 'updateBadge').arguments['count'], 0);
    ask(current, 'after-process-shutdown');
    await tester.pumpAndSettle();
    expect(shown(), hasLength(5), reason: 'Explicit process shutdown stops the notification subscription');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test('restoring history stays quiet while live events received during a load alert once', () async {
    final client = _Client();
    final session = DesktopSession(client, _Database());
    addTearDown(session.close);
    final task = DesktopTask('history', 'Saved chat');
    session.projects.add(Project('project', '/project', '/project', [task]));
    final notices = <TaskNotification>[];
    final subscription = session.notifications.listen(notices.add);
    addTearDown(subscription.cancel);
    final loading = session.loadHistory(task);
    await Future<void>.delayed(Duration.zero);
    client.events.add({
      'id': 'evt_live', 'type': 'session.question.asked', 'created': 0, 'durable': {'seq': 2},
      'data': {'sessionID': task.id, 'request': {'id': 'live', 'questions': []}},
    });
    await Future<void>.delayed(Duration.zero);
    expect(notices.map((notice) => notice.kind), [TaskNotificationKind.input]);
    client.page.complete({
      'running': true, 'through': 1, 'configuration': {}, 'state': {},
      'questions': [{'id': 'restored', 'questions': []}], 'data': [
        {'id': 'saved-idle', 'type': 'idle', 'outcome': 'succeeded',
          'time': {'created': 0}, 'metadata': {'seq': 1}},
      ],
    });
    await loading;
    await Future<void>.delayed(Duration.zero);
    expect(task.questions.keys, containsAll(['restored', 'live']));
    expect(notices.map((notice) => notice.kind), [TaskNotificationKind.input]);
  });
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  final page = Completer<Json>();
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) =>
    page.future.asCancellable(cancellation);
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'session.interrupt') return null;
    throw StateError('Unexpected request: $method');
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}

class _Database implements IsolateOwner {
  @override Future<void> close() async {}
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected database operation');
}
