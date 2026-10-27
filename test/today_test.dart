import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:paydown/api/client.dart';
import 'package:paydown/api/fake.dart';
import 'package:paydown/screens/today.dart';
import 'package:paydown/widgets.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('docs/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

Future<void> _pumpScreen(WidgetTester tester, FakeApiClient client) async {
  // Root teardown first: a different-typed root tears down the element tree,
  // dropping any Navigator routes pushed by an earlier pump in this test.
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  // Tall viewport defeats ListView child laziness so off-screen rows exist.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 10000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ApiScope(
      client: client,
      child: const MaterialApp(home: Scaffold(body: TodayScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders from mobile_home fixture', (tester) async {
    final client = FakeApiClient({'/api/mobile/home': _fixture('mobile_home')});
    await _pumpScreen(tester, client);

    // Hero
    expect(find.text('Safe to spend'), findsWidgets);
    expect(find.text('\$12,345.00'), findsAtLeastNWidgets(2));
    expect(find.text('\$12,345.00/day · 15 days'), findsOneWidget);

    // Reminders (names from fixture items)
    expect(find.text('Mortgage'), findsAtLeastNWidgets(1));
    expect(find.text('Internet'), findsAtLeastNWidgets(1));
    expect(find.text('Card C'), findsAtLeastNWidgets(1));
    // Reminders section uses shortDate: Nov 1 / Nov 6
    expect(find.text('Nov 1'), findsWidgets);
    expect(find.text('Nov 6'), findsWidgets);

    // Upcoming card row split (A7): min vs extra rendered separately
    expect(find.text('Min \$12,345.00'), findsOneWidget);
    expect(find.text('Extra \$12,345.00'), findsOneWidget);

    // Status chips from upcoming fixture
    expect(find.text('due'), findsAtLeastNWidgets(1));

    // Unlogged banner (unlogged_card_payment_count = 2)
    expect(find.text('Log 2 card payments from your bank'), findsOneWidget);

    // Hero dialog: tap → waterfall
    await tester.tap(find.text('Safe to spend').first);
    await tester.pumpAndSettle();
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('Pending out'), findsOneWidget);
    expect(find.text('Obligations'), findsOneWidget);
    expect(find.text('Planned extra'), findsOneWidget);
    expect(find.text('Movie Pass'), findsOneWidget);
    expect(
        find.text('Add your pay schedule for a more accurate number'),
        findsOneWidget);
  });

  testWidgets('banner opens unlogged flow and Log all posts log-all',
      (tester) async {
    final unloggedRow = {
      'transaction_id': 'tx1',
      'card_id': 1,
      'card_name': 'Card C',
      'date': '2026-10-12',
      'amount_cents': 1234500,
    };
    final client = FakeApiClient({
      '/api/mobile/home': _fixture('mobile_home'),
      '/api/card-payments/unlogged': [unloggedRow, unloggedRow],
      'POST /api/card-payments/log-all': {
        'items': [unloggedRow],
      },
    });
    await _pumpScreen(tester, client);

    await tester.tap(find.text('Log 2 card payments from your bank'));
    await tester.pumpAndSettle();
    expect(find.text('Unlogged card payments'), findsOneWidget);
    expect(find.text('Card C'), findsNWidgets(2));

    await tester.tap(find.text('Log all'));
    await tester.pumpAndSettle();
    expect(
        client.calls
            .where((c) => c.$1 == 'POST' && c.$2 == '/api/card-payments/log-all'),
        hasLength(1));

    // Per-row log posts to /{transaction_id}/log
    final client2 = FakeApiClient({
      '/api/mobile/home': _fixture('mobile_home'),
      '/api/card-payments/unlogged': [unloggedRow],
      'POST /api/card-payments/tx1/log': [],
    });
    await _pumpScreen(tester, client2);
    await tester.tap(find.text('Log 2 card payments from your bank'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log').first);
    await tester.pumpAndSettle();
    expect(
        client2.calls.any((c) =>
            c.$1 == 'POST' && c.$2 == '/api/card-payments/tx1/log'),
        isTrue);
  });

  testWidgets('home fetch error renders message persistently', (tester) async {
    final client = FakeApiClient({
      '/api/mobile/home': ApiError(500, 'server exploded'),
    });
    await tester.pumpWidget(
      ApiScope(
        client: client,
        child: const MaterialApp(home: Scaffold(body: TodayScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('server exploded'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
