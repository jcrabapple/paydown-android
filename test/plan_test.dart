import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:paydown/api/client.dart';
import 'package:paydown/api/fake.dart';
import 'package:paydown/screens/plan.dart';
import 'package:paydown/widgets.dart';

/// Loads the real scrubbed server response fixture.
Map<String, dynamic> mobileHomeFixture() => jsonDecode(
    File('docs/fixtures/mobile_home.json').readAsStringSync())
    as Map<String, dynamic>;

const safeToSpend = {
  'safe_to_spend_cents': 42000,
  'per_day_cents': 3000,
  'days_until': 14,
};

Future<void> pumpPlan(WidgetTester tester, FakeApiClient client) async {
  // Tall viewport defeats ListView child laziness so off-screen rows exist.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 10000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ApiScope(
    client: client,
    child: const MaterialApp(home: Scaffold(body: PlanScreen())),
  ));
  await tester.pumpAndSettle();
}

FakeApiClient fakeHome({Map<String, dynamic>? home, List? adjustments}) {
  home ??= mobileHomeFixture();
  return FakeApiClient({
    '/api/mobile/home': home,
    '/api/adjustments?month=2026-10': ?adjustments,
    '/api/safe-to-spend': safeToSpend,
  });
}

void main() {
  testWidgets('renders month header, tiles, plan rows from fixture',
      (tester) async {
    final client = fakeHome(adjustments: [
      {'id': 7, 'name': 'Tax refund', 'amount_cents': 50000, 'kind': 'bonus'},
    ]);
    await pumpPlan(tester, client);

    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('Card A'), findsOneWidget);
    expect(find.text('Card C'), findsOneWidget);
    expect(find.text('Card B'), findsOneWidget);
    // paid of recommended — scrubbed fixtures collapse distinct amounts to the
    // same round value, so the string legitimately repeats across plan rows.
    expect(find.text('\$12,345.00 of \$12,345.00'), findsWidgets);
    // Recurring extra = recurring budget - minimums (A7)
    expect(find.text('Recurring extra'), findsOneWidget);
    expect(find.text('\$0.00'), findsWidgets);
    // Use spare cash visible (current month)
    expect(find.text('Use spare cash'), findsOneWidget);
    // Adjustment listed from this month
    expect(find.text('Tax refund'), findsOneWidget);
    expect(find.text('\$500.00'), findsOneWidget);
    // Adjustments fetched scoped to the month
    expect(client.calls.any((c) => c.$1 == 'GET' &&
        c.$2 == '/api/adjustments?month=2026-10'), isTrue);
  });

  testWidgets('shows bank_overdue badge when true', (tester) async {
    final home = mobileHomeFixture();
    (home['plan'] as List)[0]['bank_overdue'] = true;
    await pumpPlan(tester, fakeHome(home: home));
    expect(find.text('Overdue'), findsOneWidget);
  });

  testWidgets('strategy picker switches projection', (tester) async {
    final home = mobileHomeFixture();
    final projection = (home['projection'] as Map)['snowball'] as Map;
    projection['months'] = 9;
    projection['total_interest_cents'] = 88000;
    await pumpPlan(tester, fakeHome(home: home));
    await tester.tap(find.text('Snowball'));
    await tester.pump();
    expect(find.textContaining('9 months'), findsOneWidget);
    expect(find.text('\$880.00'), findsOneWidget);
  });

  testWidgets('minimums_only_never renders never-pays-off text, never \$0',
      (tester) async {
    final home = mobileHomeFixture();
    home['projection']['interest_saved_cents'] = null;
    home['projection']['minimums_only_never'] = true;
    await pumpPlan(tester, fakeHome(home: home));
    expect(find.text('minimums never pay this off'), findsOneWidget);
  });

  testWidgets('use spare cash — full sweep posts no body and refetches',
      (tester) async {
    // The dialog shows cash.spare_cents (what the server sweeps), never
    // Safe-to-Spend: they are different numbers.
    final home = mobileHomeFixture();
    (home['cash'] as Map)['spare_cents'] = 42000;
    (home['safe_to_spend'] as Map)['safe_to_spend_cents'] = 99900;
    final client = fakeHome(home: home);
    await pumpPlan(tester, client);
    final homeCallsBefore =
        client.calls.where((c) => c.$2 == '/api/mobile/home').length;

    await tester.tap(find.text('Use spare cash'));
    await tester.pumpAndSettle();
    expect(find.text('Spare: \$420.00'), findsOneWidget);

    await tester.tap(find.text('Spare all (\$420.00)'));
    await tester.pumpAndSettle();

    expect(
        client.calls.any((c) =>
            c.$1 == 'POST' &&
            c.$2 == '/api/month/2026-10/use-cash' &&
            c.$3 == null),
        isTrue);
    // refetch after mutation (A3)
    final homeCallsAfter =
        client.calls.where((c) => c.$2 == '/api/mobile/home').length;
    expect(homeCallsAfter, greaterThan(homeCallsBefore));
  });

  testWidgets('use spare cash — custom amount posts amount_cents',
      (tester) async {
    final client = fakeHome();
    await pumpPlan(tester, client);
    await tester.tap(find.text('Use spare cash'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Custom amount'), '25.50');
    // Let onChanged-triggered setState enable Apply before tapping.
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
        client.calls.any((c) =>
            c.$1 == 'POST' &&
            c.$2 == '/api/month/2026-10/use-cash' &&
            c.$3?['amount_cents'] == 2550),
        isTrue);
  });

  testWidgets('add adjustment posts month/name/amount_cents', (tester) async {
    final client = fakeHome(adjustments: const []);
    await pumpPlan(tester, client);
    await tester.tap(find.byTooltip('Add adjustment'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Name'), 'Bonus paycheck');
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '120.00');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(
        client.calls.any((c) =>
            c.$1 == 'POST' &&
            c.$2 == '/api/adjustments' &&
            c.$3?['month'] == '2026-10' &&
            c.$3?['name'] == 'Bonus paycheck' &&
            c.$3?['amount_cents'] == 12000 &&
            // AdjustmentIn has no kind; the contract check rejects extras.
            !(c.$3?.containsKey('kind') ?? false)),
        isTrue);
  });

  testWidgets('delete adjustment calls DELETE with id', (tester) async {
    final client = fakeHome(adjustments: [
      {'id': 7, 'name': 'Tax refund', 'amount_cents': 50000, 'kind': 'bonus'},
    ]);
    await pumpPlan(tester, client);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(client.calls
        .any((c) => c.$1 == 'DELETE' && c.$2 == '/api/adjustments/7'), isTrue);
  });

  testWidgets('error path renders ApiError message persistently', (tester) async {
    final client = FakeApiClient({
      '/api/mobile/home': ApiError(500, 'Server exploded'),
    });
    await pumpPlan(tester, client);
    expect(find.text('Server exploded'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
