import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:paydown/api/client.dart';
import 'package:paydown/api/fake.dart';
import 'package:paydown/screens/insights.dart';
import 'package:paydown/screens/settings.dart';
import 'package:paydown/widgets.dart';

Map<String, dynamic> _fixture(String name) =>
    (jsonDecode(_readFixture(name)) as Map).cast<String, dynamic>();

// Fixtures are checked in under docs/fixtures; tests run from the repo root.
final _fixtureCache = <String, String>{};

String _readFixture(String name) => _fixtureCache.putIfAbsent(
      name,
      () => File('docs/fixtures/$name.json').readAsStringSync(),
    );

const _settings = {
  'id': 1,
  'strategy': 'avalanche',
  'buffer_cents': 1234500,
  'debt_share_pct': 50,
  'extra_override_cents': null,
  'cash_floor_cents': 1234500,
  'cash_reserve_months': 6,
  'auto_log_card_payments': true,
};

Future<void> _pump(WidgetTester tester, ApiClient client, Widget child) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 2400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ApiScope(client: client, child: Scaffold(body: child)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('InsightsScreen renders debt trend + spending from fixtures',
      (tester) async {
    final fake = FakeApiClient({
      '/api/insights/debt-trend': _fixture('insights_debt_trend'),
      '/api/insights/spending': _fixture('insights_spending'),
    });
    await _pump(tester, fake, const InsightsScreen());
    await tester.pumpAndSettle();

    // Headline = newest non-partial month (2026-06; 2026-07 is partial).
    expect(find.text('Debt trend — June 2026'), findsOneWidget);
    // Full months rendered, partial month tagged.
    expect(find.textContaining('May 2026'), findsOneWidget);
    expect(find.textContaining('July 2026 (partial)'), findsOneWidget);
    // Spending rows from fixture labels.
    expect(find.text('Shopping'), findsOneWidget);
    expect(find.text('Food & drink'), findsOneWidget);
    expect(find.textContaining(r'$12,345.00'), findsWidgets);
  });

  testWidgets('InsightsScreen hides suggestions section when absent',
      (tester) async {
    final fake = FakeApiClient({
      '/api/insights/debt-trend': _fixture('insights_debt_trend'),
      '/api/insights/spending': _fixture('insights_spending'),
    });
    await _pump(tester, fake, const InsightsScreen());
    await tester.pumpAndSettle();
    expect(find.text('Suggestions'), findsNothing);
  });

  testWidgets('InsightsScreen suggestion add POSTs a spending expense',
      (tester) async {
    final spending = _fixture('insights_spending');
    spending['suggestions'] = [
      {
        'category': 'FOOD_AND_DRINK',
        'label': 'Food & drink',
        'monthly_avg_cents': 1234500,
        'suggest': true,
        'note': null,
      },
    ];
    final fake = FakeApiClient({
      '/api/insights/debt-trend': _fixture('insights_debt_trend'),
      '/api/insights/spending': spending,
      'POST /api/expenses': {'id': 9, 'kind': 'spending'},
    });
    await _pump(tester, fake, const InsightsScreen());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await tester.pumpAndSettle();

    final post = fake.calls
        .firstWhere((c) => c.$1 == 'POST' && c.$2 == '/api/expenses');
    expect(post.$3!['kind'], 'spending');
    expect(post.$3!['amount_cents'], 1234500);
    expect(find.text('Added Food & drink'), findsOneWidget);
  });

  testWidgets('InsightsScreen error path shows ApiError message',
      (tester) async {
    final fake = FakeApiClient({
      '/api/insights/debt-trend': ApiError(500, 'boom'),
      '/api/insights/spending': _fixture('insights_spending'),
    });
    await _pump(tester, fake, const InsightsScreen());
    await tester.pumpAndSettle();
    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('SettingsScreen renders from fixtures', (tester) async {
    final fake = FakeApiClient({
      '/api/settings': _fixture('settings'),
      '/api/income': jsonDecode(_readFixture('income')) as List,
      '/api/pay-schedules': jsonDecode(_readFixture('pay_schedules')) as List,
      '/api/deposit-rules': jsonDecode(_readFixture('deposit_rules')) as List,
    });
    await _pump(tester, fake, const SettingsScreen());
    await tester.pumpAndSettle();

    expect(find.text('Avalanche'), findsOneWidget);
    expect(find.text('Buffer (\$)'), findsOneWidget);
    expect(find.text(r'$12,345.00'), findsWidgets);
    expect(find.text('Cloud Hosting'), findsOneWidget);
    expect(find.textContaining('deposits labelled'), findsNothing);
  });

  testWidgets('SettingsScreen changed fields PUT to /api/settings',
      (tester) async {
    final fake = FakeApiClient({
      '/api/settings': Map<String, dynamic>.of(_settings),
      '/api/income': <dynamic>[],
      '/api/pay-schedules': <dynamic>[],
      '/api/deposit-rules': <dynamic>[],
      'PUT /api/settings': _settings,
    });
    await _pump(tester, fake, const SettingsScreen());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Snowball'));
    await tester.pump();
    await tester.tap(find.text('Save settings'));
    await tester.pumpAndSettle();

    final put = fake.calls
        .firstWhere((c) => c.$1 == 'PUT' && c.$2 == '/api/settings');
    expect(put.$3, {'strategy': 'snowball'});
  });

  testWidgets('SettingsScreen unchanged save sends nothing', (tester) async {
    final fake = FakeApiClient({
      '/api/settings': Map<String, dynamic>.of(_settings),
      '/api/income': <dynamic>[],
      '/api/pay-schedules': <dynamic>[],
      '/api/deposit-rules': <dynamic>[],
    });
    await _pump(tester, fake, const SettingsScreen());
    await tester.pumpAndSettle();

    // Save button disabled when nothing changed.
    final save =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save settings'));
    expect(save.onPressed, isNull);
    expect(fake.calls.where((c) => c.$1 == 'PUT'), isEmpty);
  });

  testWidgets('SettingsScreen income add + delete hit the right endpoints',
      (tester) async {
    final fake = FakeApiClient({
      '/api/settings': Map<String, dynamic>.of(_settings),
      '/api/income': jsonDecode(_readFixture('income')) as List,
      '/api/pay-schedules': <dynamic>[],
      '/api/deposit-rules': <dynamic>[],
      'POST /api/income': {'id': 2},
      'DELETE /api/income/1': null,
    });
    await _pump(tester, fake, const SettingsScreen());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete').first);
    await tester.pumpAndSettle();
    // The screen refetches after a mutation, so assert presence not ordering.
    expect(fake.calls.any((c) => c.$1 == 'DELETE' && c.$2 == '/api/income/1'),
        isTrue);

    // Add: tap the income section "+" (first add button) and save the dialog.
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Side work');
    await tester.enterText(find.byType(TextField).at(1), '500');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final post = fake.calls
        .firstWhere((c) => c.$1 == 'POST' && c.$2 == '/api/income');
    expect(post.$3!['name'], 'Side work');
    expect(post.$3!['amount_cents'], 50000);
    expect(find.text('Income saved'), findsOneWidget);
  });

  testWidgets('SettingsScreen pay schedule use-as-income + detect',
      (tester) async {
    final fake = FakeApiClient({
      '/api/settings': Map<String, dynamic>.of(_settings),
      '/api/income': <dynamic>[],
      '/api/pay-schedules': [
        {
          'id': 7,
          'name': 'Day job',
          'frequency': 'biweekly',
          'anchor_date': '2026-10-02',
          'amount_cents': 150000,
          'monthly_equivalent_cents': 325000,
          'active': true,
          'next_dates': ['2026-10-30'],
        },
      ],
      '/api/deposit-rules': <dynamic>[],
      'POST /api/pay-schedules/7/use-as-income': {'id': 3},
      'POST /api/pay-schedules/detect': {'suggestion': null, 'reason': 'not enough paychecks'},
    });
    await _pump(tester, fake, const SettingsScreen());
    await tester.pumpAndSettle();

    expect(find.text('Day job'), findsOneWidget);
    await tester.tap(find.text('Use as income'));
    await tester.pumpAndSettle();
    expect(
      fake.calls.any((c) =>
          c.$1 == 'POST' && c.$2 == '/api/pay-schedules/7/use-as-income'),
      isTrue,
    );

    await tester.tap(find.text('Detect'));
    await tester.pumpAndSettle();
    expect(
      fake.calls.any((c) =>
          c.$1 == 'POST' && c.$2 == '/api/pay-schedules/detect'),
      isTrue,
    );
    expect(find.textContaining('not enough paychecks'), findsOneWidget);
  });

  testWidgets('SettingsScreen deposit rule preview dialog shows result',
      (tester) async {
    final fake = FakeApiClient({
      '/api/settings': Map<String, dynamic>.of(_settings),
      '/api/income': <dynamic>[],
      '/api/pay-schedules': <dynamic>[],
      '/api/deposit-rules': [
        {
          'id': 4,
          'match_text': 'US TREASURY',
          'label': 'Paycheck',
          'pay_schedule_id': 7,
          'pay_schedule_name': 'Day job',
          'labelled_count': 3,
        },
      ],
      '/api/deposit-rules/preview': {
        'count': 2,
        'samples': [
          {'date': '2026-10-02', 'amount_cents': 150000, 'name': 'US TREASURY 310'},
        ],
      },
    });
    await _pump(tester, fake, const SettingsScreen());
    await tester.pumpAndSettle();

    expect(find.text('Day job · 3 deposits labelled'), findsOneWidget);
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.text('2 matching deposits'), findsOneWidget);
    expect(find.textContaining('Oct 2'), findsOneWidget);
    expect(find.textContaining(r'$1,500.00'), findsOneWidget);
    final preview = fake.calls
        .firstWhere((c) => c.$1 == 'GET' && c.$2.startsWith('/api/deposit-rules/preview'));
    expect(preview.$2, contains('text=US%20TREASURY'));
  });

  testWidgets('SettingsScreen error path shows ApiError message',
      (tester) async {
    final fake = FakeApiClient({
      '/api/settings': ApiError(403, 'Cross-site request blocked'),
      '/api/income': <dynamic>[],
      '/api/pay-schedules': <dynamic>[],
      '/api/deposit-rules': <dynamic>[],
    });
    await _pump(tester, fake, const SettingsScreen());
    await tester.pumpAndSettle();
    expect(find.text('Cross-site request blocked'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
