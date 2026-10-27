import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:paydown/api/client.dart';
import 'package:paydown/api/fake.dart';
import 'package:paydown/main.dart';
import 'package:paydown/screens/more.dart';
import 'package:paydown/theme.dart';
import 'package:paydown/widgets.dart';

import 'contract.dart';

void main() {
  test('ThemeModeController persists and restores the choice', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ThemeModeController();
    await c.load();
    expect(c.mode, ThemeMode.system);

    await c.set(ThemeMode.dark);
    expect(c.mode, ThemeMode.dark);
    final stored = await SharedPreferences.getInstance();
    expect(stored.getString('theme_mode'), 'dark');

    // A fresh controller reads the persisted value back.
    final c2 = ThemeModeController();
    await c2.load();
    expect(c2.mode, ThemeMode.dark);
  });

  testWidgets('system mode follows platform brightness', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(PaydownApp(bootstrap: () async => null));
    await tester.pumpAndSettle();
    final context = tester.element(find.text('Sign in — Paydown'));
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  testWidgets('appearance picker switches and persists the theme',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeModeController();
    await theme.load();
    await tester.pumpWidget(MaterialApp(
      theme: kPaydownTheme,
      darkTheme: kPaydownDarkTheme,
      themeMode: theme.mode,
      home: Scaffold(body: MoreScreen(theme: theme)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(theme.mode, ThemeMode.dark);
    final stored = await SharedPreferences.getInstance();
    expect(stored.getString('theme_mode'), 'dark');
  });

  testWidgets('pushed routes still see ApiScope (production topology)',
      (tester) async {
    // ApiScope must wrap MaterialApp, not HomeShell: the Navigator lives
    // above `home:`, so a pushed route would lose the InheritedWidget.
    final fake = FakeApiClient({});
    await tester.pumpWidget(ApiScope(
      client: fake,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _ApiScopeProbe())),
              child: const Text('push'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.textContaining('probe-ok'), findsOneWidget);
  });

  testWidgets('fresh install (no stored creds) reaches the login screen',
      (tester) async {
    // Regression: gating on hasData spun forever because a completed
    // Credentials? future with null data reports hasData == false.
    await tester.pumpWidget(PaydownApp(bootstrap: () async => null));
    await tester.pumpAndSettle();
    expect(find.text('Sign in — Paydown'), findsOneWidget);
  });

  test('ApiError message mirrors web errText', () {
    expect(ApiError(422, 'plain detail').message, 'plain detail');
    expect(
      ApiError(422, [
        {'loc': ['body', 'name'], 'msg': 'required'},
        {'loc': ['body', 'amount_cents'], 'msg': 'too big'},
      ]).message,
      'name: required; amount_cents: too big',
    );
    expect(ApiError(500, {'a': 'b'}).message, 'a: b');
    expect(ApiError(503, null).message, 'Request failed (503)');
  });

  testWidgets('AsyncView renders loading, error (with retry), and data',
      (tester) async {
    Widget build(AsyncSnapshot<String> snap) => MaterialApp(
          home: Scaffold(
            body: AsyncView<String>(
              snapshot: snap,
              onRetry: () {},
              builder: (d) => Text('data:$d'),
            ),
          ),
        );

    await tester.pumpWidget(build(const AsyncSnapshot.waiting()));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(build(AsyncSnapshot.withError(
        ConnectionState.done, ApiError(403, 'Cross-site request blocked'))));
    await tester.pump();
    expect(find.text('Cross-site request blocked'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.pumpWidget(
        build(AsyncSnapshot.withData(ConnectionState.done, 'hello')));
    expect(find.text('data:hello'), findsOneWidget);
  });

  testWidgets('toast shows a SnackBar', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => toast(context, 'Saved'),
          child: const Text('go'),
        ),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pump(); // SnackBar entrance animation
    expect(find.text('Saved'), findsOneWidget);
    await tester.pumpAndSettle(); // let it auto-dismiss cleanly
  });

  test('contract check rejects bodies the server would 422', () async {
    // flutter_test_config installs the OpenAPI check globally; call it
    // directly here so the assertion does not trip the global tearDown.
    final check = FakeApiClient.contract!;
    FakeApiClient.contract = null;
    addTearDown(() => FakeApiClient.contract = check);
    final contract = OpenApiContract.load();
    expect(() => contract.check('POST', '/api/payments',
        {'card_id': 1, 'amount_cents': 100}), throwsA(isA<ContractError>()));
    expect(() => contract.check('POST', '/api/nope', {}),
        throwsA(isA<ContractError>()));
    expect(() => contract.check('POST', '/api/expenses',
        {'name': 'x', 'amount_cents': '100'}), throwsA(isA<ContractError>()));
    // Optional body (UseCashIn | None) unwraps to its object schema.
    contract.check('POST', '/api/month/2026-10/use-cash', {'amount_cents': 5});
    contract.check('POST', '/api/month/2026-10/use-cash', null);
  });

  test('FakeApiClient records calls and serves routes', () async {
    final fake = FakeApiClient({
      '/api/month/2026-10': {'month': '2026-10'},
      'POST /api/expenses': {'id': 1},
    });
    final m = await fake.get('/api/month/2026-10') as Map;
    expect(m['month'], '2026-10');
    final e = await fake.post(
        '/api/expenses', {'name': 'Rent', 'amount_cents': 100000}) as Map;
    expect(e['id'], 1);
    expect(fake.calls.length, 2);
    expect(fake.calls[1].$3?['name'], 'Rent');
  });
}

class _ApiScopeProbe extends StatelessWidget {
  const _ApiScopeProbe();

  @override
  Widget build(BuildContext context) {
    final client = ApiScope.of(context); // throws if the route can't see it
    return Scaffold(body: Text('probe-ok ${client.runtimeType}'));
  }
}
