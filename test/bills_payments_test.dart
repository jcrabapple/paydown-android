import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:paydown/api/client.dart';
import 'package:paydown/api/fake.dart';
import 'package:paydown/screens/bills.dart';
import 'package:paydown/screens/payments.dart';
import 'package:paydown/widgets.dart';

/// Loads a real scrubbed fixture from docs/fixtures.
dynamic fixture(String name) =>
    jsonDecode(File('docs/fixtures/$name.json').readAsStringSync());

Widget wrap(FakeApiClient client, Widget child) =>
    MaterialApp(home: ApiScope(client: client, child: child));

void _tallView(WidgetTester tester) {
  // Tall viewport defeats ListView child laziness so off-screen rows exist.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 10000);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('BillsScreen renders bills and spending tabs from fixture',
      (tester) async {
    final client = FakeApiClient({
      '/api/expenses': fixture('expenses'),
      '/api/upcoming?days=31': <dynamic>[],
    });
    _tallView(tester);
  await tester.pumpWidget(wrap(client, const BillsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Mortgage'), findsOneWidget);
    expect(find.text(r'$12,345.00'), findsNWidgets(3));
    expect(find.text('Due day 15 · from cash'), findsNWidgets(3));

    // Spending tab shows nothing (fixture has no spending rows).
    await tester.tap(find.text('Spending'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('BillsScreen mark paid records POST with due_date from upcoming',
      (tester) async {
    final client = FakeApiClient({
      '/api/expenses': [
        {
          'id': 1,
          'name': 'Mortgage',
          'amount_cents': 1234500,
          'kind': 'bill',
          'due_day': 15,
          'active': 1,
          'sort': 0,
          'paid_from': 'cash',
          'match_text': null,
        },
      ],
      '/api/upcoming?days=31': [
        {
          'date': '2026-11-01',
          'kind': 'bill',
          'id': 1,
          'name': 'Mortgage',
          'amount_cents': 1234500,
          'status': 'due',
        },
      ],
    });
    _tallView(tester);
  await tester.pumpWidget(wrap(client, const BillsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mark-paid-1')));
    await tester.pump(); // start SnackBar animation
    await tester.pump(const Duration(seconds: 5)); // let it auto-dismiss
    await tester.pumpAndSettle();

    final markCall = client.calls
        .firstWhere((c) => c.$1 == 'POST' && c.$2 == '/api/bills/1/paid');
    expect(markCall.$3, {'due_date': '2026-11-01'});
  });

  testWidgets('BillsScreen shows persistent error message', (tester) async {
    final client = FakeApiClient({
      '/api/expenses': ApiError(403, 'Cross-site request blocked'),
    });
    _tallView(tester);
  await tester.pumpWidget(wrap(client, const BillsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Cross-site request blocked'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // Error stays — it does not auto-vanish (A4).
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Cross-site request blocked'), findsOneWidget);
  });

  testWidgets('PaymentsScreen renders payments grouped by card from fixture',
      (tester) async {
    final client = FakeApiClient({
      '/api/payments?month=': fixture('payments'),
      '/api/cards': fixture('cards'),
    });
    // Route with the actual month query string.
    final now = DateTime.now();
    final month =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
    client.routes['/api/payments?month=$month'] = fixture('payments');

    _tallView(tester);
  await tester.pumpWidget(wrap(client, const PaymentsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Card A'), findsOneWidget); // group header
    expect(find.text(r'$12,345.00'), findsNWidgets(3));
    expect(find.text('Oct 12 · From your bank'), findsNWidgets(2));
    expect(find.byKey(const Key('card-group-1')), findsOneWidget);
  });

  testWidgets('PaymentsScreen log payment records POST with cents and month',
      (tester) async {
    final now = DateTime.now();
    final month =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
    final client = FakeApiClient({
      '/api/payments?month=$month': <dynamic>[],
      '/api/cards': [
        {'id': 1, 'name': 'Card A'},
      ],
    });
    _tallView(tester);
  await tester.pumpWidget(wrap(client, const PaymentsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-payment')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '2500.00');
    await tester.enterText(find.byType(TextField).last, 'Extra');
    await tester.tap(find.text('Save'));
    await tester.pump(); // dialog close + SnackBar entrance
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    final postCall = client.calls
        .firstWhere((c) => c.$1 == 'POST' && c.$2 == '/api/payments');
    final today =
        '$month-${now.day.toString().padLeft(2, '0')}';
    // paid_on is REQUIRED by PaymentIn (defaults to today in the dialog).
    expect(postCall.$3, {
      'card_id': 1,
      'amount_cents': 250000,
      'paid_on': today,
      'month': month,
      'note': 'Extra',
    });
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('PaymentsScreen shows persistent error message', (tester) async {
    final now = DateTime.now();
    final month =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
    final client = FakeApiClient({
      '/api/payments?month=$month': ApiError(500, 'boom'),
      '/api/cards': <dynamic>[],
    });
    _tallView(tester);
  await tester.pumpWidget(wrap(client, const PaymentsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('boom'), findsOneWidget);
  });
}
