import 'package:desktop/appearance.dart';
import 'package:desktop/openai_usage.dart';
import 'package:desktop/openai_usage_controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai/account_usage.dart';
import 'package:protocol/protocol.dart';

void main() {
  testWidgets('a reset selected by expiration can be retried from settings with the same redemption ID', (tester) async {
    tester.view.physicalSize = const Size(390, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final attempts = <Json>[];
    var resetApplied = false;
    var detailsAvailable = false;
    final earlierExpiry = DateTime(2030, 1, 10, 9, 30).toUtc().toIso8601String();
    final laterExpiry = DateTime(2030, 1, 20, 9, 30).toUtc().toIso8601String();
    final usage = OpenAIUsageController((method, params, {required cancellation}) async {
      if (method == openAIUsageReadMethod) {
        final count = resetApplied ? 1 : 2;
        return {
          'account_scope': 'test-account',
          'plan_type': 'pro',
          'rate_limit': {'primary_window': {'limit_window_seconds': 604800, 'used_percent': resetApplied ? 0 : 36}},
          'credits': {'balance': '144.0'},
          'rate_limit_reset_credits': {'available_count': count},
          if (detailsAvailable) 'reset_details': {'available_count': count, 'credits': [
            {'id': 'earlier-reset', 'title': 'Weekly reset', 'expires_at': earlierExpiry},
            if (!resetApplied) {'id': 'later-reset', 'title': 'Weekly reset', 'expires_at': laterExpiry},
          ]},
        };
      }
      expect(method, openAIUsageResetMethod);
      attempts.add(params);
      if (attempts.length == 1) throw StateError('Connection closed before the response arrived');
      resetApplied = true;
      return {'code': 'reset'};
    }, onRedemption: (_) {});
    addTearDown(usage.dispose);

    await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: Builder(builder: (context) => Scaffold(
      body: Align(alignment: Alignment.bottomLeft, child: OpenAIUsageMenu(usage: usage, onManage: () {
        Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: OpenAIUsageSection(usage: usage)))));
      })),
    ))));
    Future<void> tap(Finder target) async { await tester.tap(target); await tester.pumpAndSettle(); }
    Future<void> openUsage() async {
      if (find.text('Manage usage').evaluate().isEmpty) await tap(find.byTooltip('Codex usage'));
    }
    Finder useResetFor(String expiry) => find.descendant(of: find.widgetWithText(MergeSemantics, expiry),
      matching: find.widgetWithText(OutlinedButton, 'Use reset'));
    const earlier = 'Expires Jan 10, 2030 at 9:30 AM';
    const later = 'Expires Jan 20, 2030 at 9:30 AM';

    await openUsage();
    expect(find.text('Weekly limit'), findsOneWidget);
    expect(find.text('64% left'), findsOneWidget);
    expect(find.text('144 credits'), findsOneWidget);
    expect(find.text('2 available'), findsOneWidget);
    expect(find.text('Use reset'), findsNothing);

    detailsAvailable = true;
    await tap(find.byTooltip('Refresh usage'));
    expect(useResetFor(earlier), findsOneWidget);
    expect(useResetFor(later), findsOneWidget);
    await tap(useResetFor(later));
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text(later)), findsOneWidget);
    await tap(find.text('Cancel'));
    expect(attempts, isEmpty);

    await openUsage();
    await tap(useResetFor(later));
    expect(attempts, isEmpty);
    await tap(find.text('Confirm reset'));
    expect(attempts, hasLength(1));

    await openUsage();
    await tap(find.text('Manage usage'));
    await tap(useResetFor(later));
    await tap(find.text('Confirm reset'));
    expect(attempts, hasLength(2));
    expect(attempts.first['credit_id'], 'later-reset');
    expect(attempts.last['credit_id'], 'later-reset');
    expect(attempts.last['redeem_request_id'], isNotEmpty);
    expect(attempts.last['redeem_request_id'], attempts.first['redeem_request_id']);
    expect(find.text('100% left'), findsOneWidget);
    expect(find.text('1 available'), findsOneWidget);
    expect(useResetFor(earlier), findsOneWidget);
    expect(find.text(later), findsNothing);
  });
}
