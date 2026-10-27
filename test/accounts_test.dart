
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paydown/api/client.dart';
import 'package:paydown/api/fake.dart';
import 'package:paydown/screens/accounts.dart';
import 'package:paydown/format.dart';
import 'package:paydown/widgets.dart';

import 'fixtures.dart';

/// Injectable fake launcher (A6): records the link token and captures the
/// onSuccess callback so tests can drive the exchange flow. Never touches
/// plaid_flutter.
class FakeLinkLauncher implements PlaidLinkLauncher {
  final List<String> tokens = [];
  void Function(String, String)? onSuccess;
  bool disposed = false;

  @override
  void open(String linkToken,
      {required void Function(String publicToken, String institutionName)
          onSuccess}) {
    tokens.add(linkToken);
    this.onSuccess = onSuccess;
  }

  @override
  void dispose() => disposed = true;

  void emitSuccess(String publicToken, String institution) =>
      onSuccess!(publicToken, institution);
}

class _Cascade {
  FakeApiClient client;
  FakeLinkLauncher link = FakeLinkLauncher();
  _Cascade(this.client);
}

Map<String, dynamic> _baseRoutes() => {
      '/api/cash-accounts': fixtures('cash_accounts'),
      '/api/cards': fixtures('cards'),
      '/api/plaid/status': fixtures('plaid_status'),
      '/api/plaid/accounts': fixtures('plaid_accounts'),
    };

Future<_Cascade> _pump(WidgetTester tester,
    {Map<String, dynamic> extra = const {},
    Map<String, dynamic> routes = const {}}) async {
  final client = FakeApiClient({..._baseRoutes(), ...extra, ...routes});
  final link = FakeLinkLauncher();
  // Tall viewport defeats ListView child laziness so off-screen rows exist.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 10000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ApiScope(
    client: client,
    child: MaterialApp(
      home: Scaffold(body: AccountsScreen(linkLauncher: link)),
    ),
  ));
  await tester.pumpAndSettle();
  return _Cascade(client)..link = link;
}

void main() {
  testWidgets('renders cash accounts, cards and Plaid rows from fixtures',
      (tester) async {
    final c = await _pump(tester);
    expect(find.text('Main Checking'), findsOneWidget);
    expect(find.text('\$12,345.00'), findsWidgets); // every balance
    expect(find.text('Card A'), findsOneWidget);
    expect(find.text('APR 24.99%'), findsNWidgets(3));
    expect(find.text('Min \$12,345.00'), findsNWidgets(3));
    expect(find.text('Due Nov 2'), findsOneWidget);
    expect(find.text('Synced via Plaid'), findsNWidgets(3));
    // utilization bar for the card that has utilization_pct
    expect(find.byKey(const Key('card-util-1')), findsOneWidget);
    // plaid items + accounts
    expect(find.text('Example Bank'), findsWidgets);
    // Sync date derived from the fixture (the daily sync moves it forward).
    final synced =
        'Synced ${shortDate((fixtures('plaid_status')['items'] as List).first['last_synced_at'] as String)}';
    expect(find.textContaining(synced), findsNWidgets(3));
    expect(find.textContaining('Accounts: 2'), findsNWidgets(3));
    expect(find.text('Savings ••0001'), findsOneWidget);
    expect(find.text('Linked: Card A · Example Bank'),
        findsOneWidget);
    expect(find.text('Linked: unlinked · Example Bank'), findsNWidgets(2));
    expect(c.link.disposed, isFalse);
  });

  testWidgets('hides the Plaid section when configured is false',
      (tester) async {
    await _pump(tester, extra: {
      '/api/plaid/status': {'configured': false},
    });
    expect(find.text('Plaid'), findsNothing);
    expect(find.byKey(const Key('plaid-sync')), findsNothing);
    expect(find.text('Savings ••0001'), findsNothing);
  });

  testWidgets('error path: fetch failure surfaces the message persistently',
      (tester) async {
    await _pump(tester, routes: {
      '/api/cash-accounts': ApiError(500, 'boom'),
    });
    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Main Checking'), findsNothing);
  });

  testWidgets('include_in_cash switch records PUT with flipped value',
      (tester) async {
    final c = await _pump(tester, extra: {
      'PUT /api/cash-accounts/1': {'ok': true},
    });
    await tester.tap(find.byKey(const Key('cash-include-1')));
    await tester.pumpAndSettle();
    final put = c.client.calls
        .map((r) => (r.$1, r.$2, r.$3))
        .where((r) => r.$1 == 'PUT')
        .toList();
    expect(put, hasLength(1));
    expect(put.single.$2, '/api/cash-accounts/1');
    expect(put.single.$3, {
      'name': 'Main Checking',
      'balance_cents': 1234500,
      'include_in_cash': false,
    });
  });

  testWidgets('add cash account converts dollars to cents',
      (tester) async {
    final c = await _pump(tester, extra: {
      'POST /api/cash-accounts': {'id': 9},
    });
    await tester.tap(find.byKey(const Key('cash-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cash-name')), 'Ally');
    await tester.enterText(find.byKey(const Key('cash-balance')), '\$1,234.56');
    await tester.tap(find.byKey(const Key('cash-save')));
    await tester.pumpAndSettle();
    final post = c.client.calls
        .where((r) => r.$1 == 'POST' && r.$2 == '/api/cash-accounts')
        .toList();
    expect(post, hasLength(1));
    expect(post.single.$3, {'name': 'Ally', 'balance_cents': 123456});
  });

  testWidgets('clear overrides on a synced card sends explicit nulls',
      (tester) async {
    // The Clear action only appears when the card HAS an override.
    final cards = (fixtures('cards') as List)
        .map((e) => Map<String, dynamic>.of(e as Map<String, dynamic>))
        .toList();
    cards[0]['apr_override'] = 29.99;
    final c = await _pump(tester, extra: {
      '/api/cards': cards,
      'PUT /api/cards/1': {'ok': true},
    });
    // open the first card's edit dialog (first edit icon in the cards section)
    await tester.tap(find.byIcon(Icons.edit_outlined).at(3)); // after 3 cash rows
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('card-clear-overrides')));
    await tester.pumpAndSettle();
    final put = c.client.calls.where((r) => r.$1 == 'PUT').toList();
    expect(put, hasLength(1));
    expect(put.single.$2, '/api/cards/1');
    expect(put.single.$3, {'apr_override': null, 'min_override_cents': null});
  });

  testWidgets('synced card edit sends overrides; blank means use the bank',
      (tester) async {
    // Reverses the old test: synced cards are exactly where overrides are
    // needed (Plaid sends no APR / a \$0 minimum), so the fields are editable.
    final c = await _pump(tester, extra: {
      'PUT /api/cards/1': {'ok': true},
    });
    await tester.tap(find.byIcon(Icons.edit_outlined).at(3));
    await tester.pumpAndSettle();
    expect(find.text('APR override (%)'), findsOneWidget);
    expect(find.byKey(const Key('card-edit-balance')), findsNothing);
    await tester.enterText(find.byKey(const Key('card-edit-name')), 'Renamed');
    await tester.enterText(find.byKey(const Key('card-edit-apr')), '29.99');
    await tester.enterText(find.byKey(const Key('card-edit-min')), '');
    await tester.tap(find.byKey(const Key('card-edit-save')));
    await tester.pumpAndSettle();
    final put = c.client.calls.where((r) => r.$1 == 'PUT').toList();
    expect(put.single.$3, {
      'name': 'Renamed',
      'apr_override': 29.99,
      'min_override_cents': null,
    });
  });

  testWidgets('manual card edit sends real apr/min/balance, validates inline',
      (tester) async {
    final cards = (fixtures('cards') as List)
        .map((e) => Map<String, dynamic>.of(e as Map<String, dynamic>))
        .toList();
    cards[0]
      ..['sync'] = 'manual'
      ..['bank_apr'] = 19.99
      ..['bank_min_payment_cents'] = 3500;
    final c = await _pump(tester, extra: {
      '/api/cards': cards,
      'PUT /api/cards/1': {'ok': true},
    });
    await tester.tap(find.byIcon(Icons.edit_outlined).at(3));
    await tester.pumpAndSettle();
    expect(find.text('APR (%)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('card-edit-balance')), '1,000');
    await tester.enterText(find.byKey(const Key('card-edit-apr')), 'abc');
    await tester.tap(find.byKey(const Key('card-edit-save')));
    await tester.pumpAndSettle();
    expect(find.text('APR must be a number from 0 to 100.'), findsOneWidget);
    expect(c.client.calls.where((r) => r.$1 == 'PUT'), isEmpty);
    await tester.enterText(find.byKey(const Key('card-edit-apr')), '21.5');
    await tester.tap(find.byKey(const Key('card-edit-save')));
    await tester.pumpAndSettle();
    final put = c.client.calls.where((r) => r.$1 == 'PUT').toList();
    expect(put.single.$3, {
      'name': cards[0]['name'],
      'balance_cents': 100000,
      'apr': 21.5,
      'min_payment_cents': 3500,
    });
  });

  testWidgets('bank_apr renders grayed when override differs', (tester) async {
    await _pump(tester, extra: {
      '/api/cards': [
        {
          ...fixtures('cards')[0],
          'apr_override': 29.99,
          'min_override_cents': 2500,
        }
      ],
    });
    expect(find.text('APR 29.99%'), findsOneWidget);
    expect(find.byKey(const Key('card-bank-apr-1')), findsOneWidget);
    expect(find.text('bank 24.99%'), findsOneWidget);
    expect(find.text('bank \$12,345.00'), findsOneWidget);
    expect(find.text('Min \$25.00'), findsOneWidget);
  });

  testWidgets('delete item with confirm records DELETE', (tester) async {
    final c = await _pump(tester, extra: {
      'DELETE /api/plaid/items/1': null,
    });
    await tester.tap(find.byKey(const Key('plaid-item-delete-1')).first);
    await tester.pumpAndSettle();
    expect(find.text('Remove bank connection'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(
        c.client.calls.any((r) =>
            r.$1 == 'DELETE' && r.$2 == '/api/plaid/items/1'), isTrue);
  });

  testWidgets('Sync now records POST /api/plaid/sync', (tester) async {
    final c = await _pump(tester, extra: {
      'POST /api/plaid/sync': {'ok': true},
    });
    await tester.tap(find.byKey(const Key('plaid-sync')));
    await tester.pumpAndSettle();
    expect(
        c.client.calls
            .any((r) => r.$1 == 'POST' && r.$2 == '/api/plaid/sync'),
        isTrue);
  });

  testWidgets('Connect bank: link-token → launcher → exchange',
      (tester) async {
    final c = await _pump(tester, extra: {
      'POST /api/plaid/link-token': {'link_token': 'link-sandbox-fake'},
      'POST /api/plaid/exchange': {'ok': true},
    });
    await tester.tap(find.byKey(const Key('plaid-connect')));
    await tester.pumpAndSettle();
    final tokenCall = c.client.calls
        .where((r) => r.$1 == 'POST' && r.$2 == '/api/plaid/link-token')
        .single;
    expect(tokenCall.$3, {'android_package_name': 'us.snakepit.paydown'});
    expect(c.link.tokens, ['link-sandbox-fake']);
    expect(c.client.calls.any((r) => r.$2 == '/api/plaid/exchange'), isFalse,
        reason: 'exchange only happens after Link success');
    c.link.emitSuccess('public-sandbox-fake', 'Test Bank');
    await tester.pumpAndSettle();
    final exchange = c.client.calls
        .where((r) => r.$1 == 'POST' && r.$2 == '/api/plaid/exchange')
        .single;
    expect(exchange.$3,
        {'public_token': 'public-sandbox-fake', 'institution_name': 'Test Bank'});
  });

  testWidgets('unlink a plaid account records POST .../unlink',
      (tester) async {
    final c = await _pump(tester, extra: {
      'POST /api/plaid/accounts/1/unlink': {'ok': true},
    });
    await tester.tap(find.byKey(const Key('plaid-account-menu-1')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlink').last);
    await tester.pumpAndSettle();
    expect(
        c.client.calls.any((r) =>
            r.$1 == 'POST' && r.$2 == '/api/plaid/accounts/1/unlink'),
        isTrue);
  });

  testWidgets('action error surfaces in the persistent banner', (tester) async {
    await _pump(tester, extra: {
      'POST /api/plaid/sync': ApiError(502, 'plaid down'),
    });
    await tester.tap(find.byKey(const Key('plaid-sync')));
    await tester.pumpAndSettle();
    expect(find.text('plaid down'), findsOneWidget);
  });
}
