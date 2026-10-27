import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paydown/api/client.dart';
import 'package:paydown/api/fake.dart';
import 'package:paydown/screens/goals.dart';
import 'package:paydown/screens/subscriptions.dart';
import 'package:paydown/widgets.dart';

Future<FakeApiClient> _pumpSubs(WidgetTester tester,
        [Map<String, dynamic>? extra]) async =>
    _pump(tester, const SubscriptionsScreen(), {
      '/api/subscriptions': {
        'active': [
          {
            'id': 1,
            'name': 'Netflix',
            'amount_cents': 1533,
            'cycle': 'monthly',
            'status': 'active',
            'monthly_cents': 1533,
            'annual_cents': 18396,
            'next_renewal': '2026-11-01',
            'days_until': 5,
          },
          {
            'id': 2,
            'name': 'Prime',
            'amount_cents': 13900,
            'cycle': 'yearly',
            'status': 'active',
            'monthly_cents': 1158,
            'annual_cents': 13900,
            'next_renewal': '2027-03-01',
            'days_until': 125,
          },
        ],
        'cancelled': [
          {
            'id': 3,
            'name': 'Old Gym',
            'amount_cents': 3000,
            'cycle': 'monthly',
            'status': 'cancelled',
            'cancelled_on': '2026-09-01',
            'monthly_cents': 3000,
            'annual_cents': 36000,
          },
        ],
        'totals': {
          'monthly_cents': 2691,
          'annual_cents': 32296,
          'active_count': 2,
          'cancelled_count': 1,
        },
      },
      '/api/subscriptions/suggestions': [
        {
          'key': 'netflix com',
          'name': 'Netflix',
          'amount_cents': 1533,
          'cycle': 'monthly',
          'next_date': '2026-11-01',
          'match_text': 'netflix',
          'last_date': '2026-10-01',
          'occurrences': 6,
          'bill_id': 7,
          'bill_name': 'Streaming',
        },
      ],
      ...?extra,
    });

Future<FakeApiClient> _pumpGoals(WidgetTester tester,
        [Map<String, dynamic>? extra]) async =>
    _pump(tester, const GoalsScreen(), {
      '/api/goals': [
        {
          'id': 1,
          'name': 'Car repairs',
          'target_cents': 120000,
          'target_date': '2027-04-01',
          'active': true,
          'set_aside_cents': 30000,
          'progress_pct': 25.0,
          'per_paycheck_cents': 10000,
          'monthly_need_cents': 20000,
        },
      ],
      ...?extra,
    });

Future<FakeApiClient> _pump(WidgetTester tester, Widget screen,
    Map<String, dynamic> routes) async {
  // Tall viewport defeats ListView child laziness so off-screen rows exist.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 10000);
  addTearDown(tester.view.reset);
  final fake = FakeApiClient(routes);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ApiScope(client: fake, child: screen),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  testWidgets('subscriptions render totals, active rows and cancelled tile',
      (tester) async {
    await _pumpSubs(tester);
    expect(find.text(r'$26.91'), findsOneWidget); // totals monthly_cents
    expect(find.text(r'$322.96'), findsOneWidget); // totals annual_cents
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Netflix · monthly'), findsNWidgets(2)); // active row + its detection suggestion
    expect(find.text(r'$139.00/yr · $11.58/mo'), findsOneWidget);
    expect(find.text('Cancelled (1)'), findsOneWidget);
    expect(find.text('Detected (1)'), findsOneWidget);
  });

  testWidgets('cancel action records POST .../cancel with cancelled_on',
      (tester) async {
    final fake = await _pumpSubs(tester, {
      'POST /api/subscriptions/1/cancel': {'id': 1},
    });
    await tester.tap(find.byKey(const ValueKey('sub-menu-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel sub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(
      fake.calls.any((c) =>
          c.$1 == 'POST' && c.$2 == '/api/subscriptions/1/cancel' && c.$3 != null && c.$3!['cancelled_on'] is String),
      isTrue,
    );
  });

  testWidgets('dismiss suggestion records POST with the suggestion key',
      (tester) async {
    final fake = await _pumpSubs(tester, {
      'POST /api/subscriptions/suggestions/dismiss': null,
    });
    await tester.tap(find.byKey(const ValueKey('suggestion-netflix com')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dismiss-suggestion')));
    await tester.pumpAndSettle();
    expect(
      fake.calls.any((c) =>
          c.$1 == 'POST' &&
          c.$2 == '/api/subscriptions/suggestions/dismiss' &&
          c.$3 != null &&
          c.$3!['key'] == 'netflix com'),
      isTrue,
    );
  });

  testWidgets('convert-bill suggestion records POST /from-expense/{bill_id}',
      (tester) async {
    final fake = await _pumpSubs(tester, {
      'POST /api/subscriptions/from-expense/7': {'id': 9},
    });
    await tester.tap(find.byKey(const ValueKey('suggestion-netflix com')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('convert-bill')));
    await tester.pumpAndSettle();
    expect(
      fake.calls.any((c) =>
          c.$1 == 'POST' && c.$2 == '/api/subscriptions/from-expense/7'),
      isTrue,
    );
  });

  testWidgets('subscriptions fetch error shows the ApiError message',
      (tester) async {
    await _pump(tester, const SubscriptionsScreen(), {
      '/api/subscriptions': ApiError(500, 'Subs are down'),
    });
    expect(find.text('Subs are down'), findsOneWidget);
  });

  testWidgets('goals render name, progress and target date',
      (tester) async {
    await _pumpGoals(tester);
    expect(find.text('Car repairs'), findsOneWidget);
    expect(find.text(r'$300.00 of $1,200.00'), findsOneWidget);
    expect(find.textContaining('By Apr 1'), findsOneWidget);
  });

  testWidgets('set aside records POST /api/goals/{id}/move with cents + note',
      (tester) async {
    final fake = await _pumpGoals(tester, {
      'POST /api/goals/1/move': {'id': 1},
    });
    await tester.tap(find.byKey(const ValueKey('set-aside-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Amount'), '50.00');
    await tester.enterText(
        find.widgetWithText(TextField, 'Note (optional)'), 'cash');
    await tester.tap(find.widgetWithText(FilledButton, 'Set aside'));
    await tester.pumpAndSettle();
    expect(
      fake.calls.any((c) =>
          c.$1 == 'POST' &&
          c.$2 == '/api/goals/1/move' &&
          c.$3 != null &&
          c.$3!['amount_cents'] == 5000 &&
          c.$3!['note'] == 'cash'),
      isTrue,
    );
  });

  testWidgets('use records a negative move (release back to cash)',
      (tester) async {
    final fake = await _pumpGoals(tester, {
      'POST /api/goals/1/move': {'id': 1},
    });
    await tester.tap(find.byKey(const ValueKey('use-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Amount'), '10');
    await tester.tap(find.widgetWithText(FilledButton, 'Use'));
    await tester.pumpAndSettle();
    expect(
      fake.calls.any((c) =>
          c.$1 == 'POST' &&
          c.$2 == '/api/goals/1/move' &&
          c.$3 != null &&
          c.$3!['amount_cents'] == -1000),
      isTrue,
    );
  });

  testWidgets('goals fetch error shows the ApiError message',
      (tester) async {
    await _pump(tester, const GoalsScreen(), {
      '/api/goals': ApiError(500, 'Goals are down'),
    });
    expect(find.text('Goals are down'), findsOneWidget);
  });
}
