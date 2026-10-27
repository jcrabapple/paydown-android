import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:paydown/api/auth.dart';
import 'package:paydown/api/client.dart';
import 'package:paydown/api/fake.dart';
import 'package:paydown/format.dart';
import 'package:paydown/screens/bills.dart';
import 'package:paydown/screens/insights.dart';
import 'package:paydown/screens/login.dart';
import 'package:paydown/screens/payments.dart';
import 'package:paydown/screens/today.dart';
import 'package:paydown/widgets.dart';

/// Regression tests for the pre-open-source bugfix pass.
void main() {
  group('parseCents', () {
    test('accepts common typed forms exactly', () {
      expect(parseCents('1234.56'), 123456);
      expect(parseCents(r'$1,234.56'), 123456);
      expect(parseCents(' 1,200 '), 120000); // was 0 in bills/payments
      expect(parseCents('12.5'), 1250);
      expect(parseCents('.99'), 99);
      expect(parseCents('0.29'), 29); // double math gives 28.999...
      expect(parseCents('0'), 0);
    });
    test('rejects junk instead of guessing', () {
      expect(parseCents(''), isNull);
      expect(parseCents('   '), isNull);
      expect(parseCents('abc'), isNull);
      expect(parseCents('-5'), isNull);
      expect(parseCents('1.234'), isNull);
      expect(parseCents('1.2.3'), isNull);
      expect(parseCents('99999999999999999999'), isNull);
    });
    test('centsText round-trips', () {
      for (final c in [0, 5, 99, 100, 123456]) {
        expect(parseCents(centsText(c)), c);
      }
    });
  });

  group('normalizeBaseUrl', () {
    test('adds https and strips trailing slashes', () {
      expect(normalizeBaseUrl('budget.example.com'),
          'https://budget.example.com');
      expect(normalizeBaseUrl('https://budget.example.com///'),
          'https://budget.example.com');
      expect(normalizeBaseUrl(' http://10.0.2.2:8485/ '),
          'http://10.0.2.2:8485');
    });
    test('rejects unusable input', () {
      expect(normalizeBaseUrl(''), isNull);
      expect(normalizeBaseUrl('ftp://x.example'), isNull);
      expect(normalizeBaseUrl('https://'), isNull);
    });
  });

  group('HttpApiClient', () {
    const creds = Credentials('u', 'p');
    HttpApiClient client(MockClient mock,
            {Duration timeout = const Duration(seconds: 20)}) =>
        HttpApiClient(
            baseUrl: 'https://x.example/',
            auth: AuthStore(),
            credentials: creds,
            client: mock,
            timeout: timeout);

    test('trailing slash does not double the path separator', () async {
      late Uri seen;
      final c = client(MockClient((req) async {
        seen = req.url;
        return http.Response('{}', 200);
      }));
      await c.get('/api/settings');
      expect(seen.toString(), 'https://x.example/api/settings');
    });

    test('non-JSON 200 (proxy page) becomes a readable ApiError', () async {
      final c = client(MockClient(
          (_) async => http.Response('<html>Sign in to Wi-Fi</html>', 200)));
      expect(
          c.get('/api/settings'),
          throwsA(isA<ApiError>().having(
              (e) => e.message, 'message', contains('Unexpected response'))));
    });

    test('a hung request times out instead of spinning forever', () async {
      final c = client(
          MockClient((_) => Completer<http.Response>().future),
          timeout: const Duration(milliseconds: 50));
      expect(
          c.get('/api/settings'),
          throwsA(isA<ApiError>()
              .having((e) => e.message, 'message', contains('too long'))));
    });

    test('401 says wrong credentials; FastAPI detail survives otherwise',
        () async {
      final c401 = client(MockClient((_) async => http.Response(
          jsonEncode({'detail': 'Not authenticated'}), 401)));
      expect(
          c401.get('/api/settings'),
          throwsA(isA<ApiError>().having(
              (e) => e.message, 'message', 'Wrong user or password.')));
      final c422 = client(MockClient((_) async =>
          http.Response(jsonEncode({'detail': 'amount must be positive'}), 422)));
      expect(
          c422.post('/api/payments', {}),
          throwsA(isA<ApiError>().having(
              (e) => e.message, 'message', 'amount must be positive')));
    });

    test('never sends an Origin header (CSRF guard contract D4)', () async {
      late Map<String, String> headers;
      final c = client(MockClient((req) async {
        headers = req.headers;
        return http.Response('{}', 200);
      }));
      await c.post('/api/expenses', {'name': 'x', 'amount_cents': 1});
      expect(headers.keys.map((k) => k.toLowerCase()), isNot(contains('origin')));
      expect(headers['Authorization'], startsWith('Basic '));
    });
  });

  testWidgets('failed sign-in leaves nothing in secure storage',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final auth = AuthStore();
    var succeeded = false;
    await tester.pumpWidget(MaterialApp(
        home: LoginScreen(auth: auth, onSuccess: () => succeeded = true)));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Server'), 'budget.example.com');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'User'), 'someone');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'wrong');
    // flutter_test's HttpOverrides answer every real request with 400.
    await tester.runAsync(() async {
      await tester.tap(find.text('Sign in'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(succeeded, isFalse);
    expect(await auth.read(), isNull);
  });

  group('amount entry', () {
    void tall(WidgetTester tester) {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 10000);
      addTearDown(tester.view.reset);
    }

    testWidgets('bill amount "1,200" saves 120000, not \$0', (tester) async {
      tall(tester);
      final client = FakeApiClient({
        '/api/expenses': <dynamic>[],
        '/api/upcoming?days=31': <dynamic>[],
        'POST /api/expenses': {'id': 1},
      });
      await tester.pumpWidget(MaterialApp(
          home: ApiScope(client: client, child: const BillsScreen())));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-bill')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Rent');
      await tester.enterText(find.widgetWithText(TextField, 'Amount'), '1,200');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final post = client.calls.firstWhere((c) => c.$1 == 'POST');
      expect(post.$3?['amount_cents'], 120000);
    });

    testWidgets('payment with junk amount stays open with an error, no POST',
        (tester) async {
      tall(tester);
      final now = DateTime.now();
      final month =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
      final client = FakeApiClient({
        '/api/payments?month=$month': <dynamic>[],
        '/api/cards': [
          {'id': 1, 'name': 'Card A'},
        ],
      });
      await tester.pumpWidget(MaterialApp(
          home: ApiScope(client: client, child: const PaymentsScreen())));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-payment')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Amount'), '12.345');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Enter an amount'), findsOneWidget);
      expect(client.calls.where((c) => c.$1 == 'POST'), isEmpty);
    });
  });

  testWidgets('showError persists past the toast timeout', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showError(context, 'server exploded'),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    expect(find.text('server exploded'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('server exploded'), findsNothing);
  });

  test('401 fires onUnauthorized so the session can sign out', () async {
    var fired = 0;
    final c = HttpApiClient(
      baseUrl: 'https://x.example',
      auth: AuthStore(),
      credentials: const Credentials('u', 'p'),
      client: MockClient((_) async => http.Response('{"detail":"no"}', 401)),
      onUnauthorized: () => fired++,
    );
    await expectLater(c.get('/api/settings'), throwsA(isA<ApiError>()));
    expect(fired, 1);
  });

  group('unlogged card payments page', () {
    Map<String, dynamic> row(String id) => {
          'transaction_id': id,
          'card_id': 1,
          'card_name': 'Card $id',
          'date': '2026-10-12',
          'amount_cents': 5000,
        };

    Future<FakeApiClient> pumpPage(
        WidgetTester tester, Map<String, dynamic> routes) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 10000);
      addTearDown(tester.view.reset);
      final client = FakeApiClient(routes);
      await tester.pumpWidget(ApiScope(
        client: client,
        child: const MaterialApp(home: UnloggedCardPaymentsPage()),
      ));
      await tester.pumpAndSettle();
      return client;
    }

    testWidgets('Log all clears the list from the server, not a local guess',
        (tester) async {
      var logged = false;
      final client = await pumpPage(tester, {
        // log-all answers {logged, linked}: no rows to diff locally.
        '/api/card-payments/unlogged': (_) =>
            logged ? <dynamic>[] : [row('a'), row('b')],
        'POST /api/card-payments/log-all': (_) {
          logged = true;
          return {'logged': 2, 'linked': 0};
        },
      });
      expect(find.text('Card a'), findsOneWidget);
      await tester.tap(find.text('Log all'));
      await tester.pumpAndSettle();
      expect(find.text('Card a'), findsNothing);
      expect(find.text('Nothing to log'), findsOneWidget);
      expect(client.calls.where((c) => c.$1 == 'POST'), hasLength(1));
    });

    testWidgets('Dismiss says Dismissed and each row has its own buttons',
        (tester) async {
      var dismissed = false;
      await pumpPage(tester, {
        '/api/card-payments/unlogged': (_) =>
            dismissed ? [row('b')] : [row('a'), row('b')],
        'POST /api/card-payments/a/dismiss': (_) {
          dismissed = true;
          return null;
        },
      });
      // Buttons live inside the row's card, not in a detached second list.
      final cardA = find.ancestor(
          of: find.text('Card a'), matching: find.byType(Card));
      expect(find.descendant(of: cardA, matching: find.text('Dismiss')),
          findsOneWidget);
      await tester.tap(find.descendant(of: cardA, matching: find.text('Dismiss')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Dismissed'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Card a'), findsNothing);
      expect(find.text('Card b'), findsOneWidget);
    });

    testWidgets('a second tap while busy sends no duplicate POST',
        (tester) async {
      final gate = Completer<void>();
      final client = await pumpPage(tester, {
        '/api/card-payments/unlogged': (_) => [row('a')],
        'POST /api/card-payments/a/log': (_) async {
          await gate.future;
          return {'id': 1};
        },
      });
      await tester.tap(find.text('Log'));
      await tester.pump();
      await tester.tap(find.text('Log'), warnIfMissed: false);
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(
          client.calls.where(
              (c) => c.$1 == 'POST' && c.$2 == '/api/card-payments/a/log'),
          hasLength(1));
    });
  });

  testWidgets('Spending tab FAB adds a spending expense', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 10000);
    addTearDown(tester.view.reset);
    final client = FakeApiClient({
      '/api/expenses': <dynamic>[],
      '/api/upcoming?days=31': <dynamic>[],
      'POST /api/expenses': {'id': 1},
    });
    await tester.pumpWidget(MaterialApp(
        home: ApiScope(client: client, child: const BillsScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Spending'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-bill')));
    await tester.pumpAndSettle();
    expect(find.text('Add spending'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Groceries');
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '400');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final post = client.calls.firstWhere((c) => c.$1 == 'POST');
    expect(post.$3?['kind'], 'spending');
  });

  testWidgets('debt trend drops pre-history partial months, keeps current',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(2400, 10000);
    addTearDown(tester.view.reset);
    Map<String, dynamic> m(String month, bool partial, int net) => {
          'month': month,
          'partial': partial,
          'charges_cents': 0,
          'payments_cents': 0,
          'refunds_cents': 0,
          'interest_cents': 0,
          'fees_cents': 0,
          'net_change_cents': net,
        };
    final client = FakeApiClient({
      '/api/insights/debt-trend': {
        'coverage_start': '2026-08-05',
        'months': [
          m('2026-07', true, 0), // before bank history: drop
          m('2026-08', false, -5000), // paid down: good
          m('2026-09', false, 7000), // debt grew: bad
          m('2026-10', true, 100), // current month: keep, tagged
        ],
      },
      '/api/insights/spending': {'categories': <dynamic>[]},
    });
    await tester.pumpWidget(MaterialApp(
        home: ApiScope(
            client: client, child: const Scaffold(body: InsightsScreen()))));
    await tester.pumpAndSettle();
    expect(find.textContaining('July 2026'), findsNothing);
    expect(find.textContaining('October 2026 (partial)'), findsOneWidget);
    final theme = Theme.of(tester.element(find.byType(InsightsScreen)));
    Color? colorOf(String text) =>
        tester.widget<Text>(find.text(text)).style?.color;
    expect(colorOf(r'-$50.00'), isNot(theme.colorScheme.error));
    expect(colorOf(r'$70.00'), theme.colorScheme.error);
  });

  testWidgets('there is no default server: blank Server blocks sign-in',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    var succeeded = false;
    await tester.pumpWidget(MaterialApp(
        home: LoginScreen(auth: AuthStore(), onSuccess: () => succeeded = true)));
    final server = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Server'));
    expect(server.controller!.text, isEmpty);
    await tester.enterText(find.widgetWithText(TextFormField, 'User'), 'u');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'p');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter your server address'), findsOneWidget);
    expect(succeeded, isFalse);
  });

  testWidgets('bill subtitle shows the next due date once, not "Due day N"',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 10000);
    addTearDown(tester.view.reset);
    final client = FakeApiClient({
      '/api/expenses': [
        {'id': 1, 'name': 'Rent', 'amount_cents': 165000, 'kind': 'bill',
         'due_day': 1, 'paid_from': 'cash', 'active': 1, 'sort': 0},
      ],
      '/api/upcoming?days=31': [
        {'date': '2026-11-01', 'kind': 'bill', 'id': 1, 'name': 'Rent',
         'amount_cents': 165000, 'status': 'due'},
      ],
    });
    await tester.pumpWidget(MaterialApp(
        home: ApiScope(client: client, child: const BillsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Due Nov 1 · from cash'), findsOneWidget);
    expect(find.textContaining('Due day'), findsNothing);
  });

  testWidgets('Today hides a zero planned extra on card rows', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 10000);
    addTearDown(tester.view.reset);
    final home = jsonDecode(File('docs/fixtures/mobile_home.json')
        .readAsStringSync()) as Map<String, dynamic>;
    for (final u in (home['upcoming'] as List).cast<Map>()) {
      if (u['kind'] == 'card') u['extra_remaining_cents'] = 0;
    }
    await tester.pumpWidget(MaterialApp(
        home: ApiScope(
            client: FakeApiClient({'/api/mobile/home': home}),
            child: const Scaffold(body: TodayScreen()))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Min '), findsWidgets);
    expect(find.textContaining('Extra '), findsNothing);
  });
}
