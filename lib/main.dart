import 'package:flutter/material.dart';

import 'api/auth.dart';
import 'api/client.dart';
import 'screens/accounts.dart';
import 'screens/login.dart';
import 'screens/more.dart';
import 'screens/plan.dart';
import 'screens/today.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PaydownApp());
}

class PaydownApp extends StatefulWidget {
  const PaydownApp({super.key, this.bootstrap});

  /// Credential read for the session gate; injectable in tests. Defaults to
  /// reading platform secure storage.
  final Future<Credentials?> Function()? bootstrap;

  @override
  State<PaydownApp> createState() => _PaydownAppState();
}

class _PaydownAppState extends State<PaydownApp> {
  final AuthStore _auth = AuthStore();
  final ThemeModeController _theme = ThemeModeController();
  int _session = 0;

  @override
  void initState() {
    super.initState();
    _theme.load();
  }

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _theme,
        builder: (context, _) => MaterialApp(
          title: 'Paydown',
          theme: kPaydownTheme,
          darkTheme: kPaydownDarkTheme,
          themeMode: _theme.mode,
          home: FutureBuilder<Credentials?>(
            // Re-reads credentials when the session key bumps (sign-in/out).
            key: ValueKey(_session),
            future: (widget.bootstrap ?? _auth.read)(),
            builder: (context, snap) {
              // Gate on connectionState, never hasData: a completed future with
              // no stored credentials has data null, and hasData would spin
              // forever on the loading screen.
              if (snap.connectionState != ConnectionState.done) {
                return const Scaffold(
                    body: Center(child: CircularProgressIndicator()));
              }
              if (snap.hasError) {
                return Scaffold(
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Could not read stored credentials.'),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: () => setState(() => _session++),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return _Root(
                auth: _auth,
                creds: snap.data,
                theme: _theme,
                onSessionChange: () => setState(() => _session++),
              );
            },
          ),
        ),
      );
}

/// Session root: builds the ApiClient for the stored credentials and shows
/// either the login gate or the navigation shell.
///
/// Stateful so the client lives for the whole session: the FutureBuilder
/// above is keyed by the session counter, so sign-in/out creates a fresh
/// _Root state, while theme rebuilds reuse this one. Building the client in
/// build() leaked an unclosed http.Client per rebuild and re-notified every
/// ApiScope dependent.
class _Root extends StatefulWidget {
  const _Root({
    required this.auth,
    required this.creds,
    required this.theme,
    required this.onSessionChange,
  });

  final AuthStore auth;
  final Credentials? creds;
  final ThemeModeController theme;
  final VoidCallback onSessionChange;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  HttpApiClient? _client;
  bool _signingOut = false;

  /// Stored credentials were rejected: sign out once (several screens may
  /// 401 at the same moment) and fall back to the login screen.
  Future<void> _credentialsRejected() async {
    if (_signingOut || !mounted) return;
    _signingOut = true;
    await widget.auth.clear();
    if (mounted) widget.onSessionChange();
  }

  @override
  void initState() {
    super.initState();
    final creds = widget.creds;
    final baseUrl = creds?.baseUrl;
    // No stored server = treat as signed out (there is no default server).
    if (creds != null && baseUrl != null) {
      _client = HttpApiClient(
        baseUrl: baseUrl,
        auth: widget.auth,
        credentials: creds, // fixed for the session; no keystore read per call
        onUnauthorized: _credentialsRejected,
      );
    }
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    if (client == null) {
      return MaterialApp(
        title: 'Paydown',
        theme: kPaydownTheme,
        darkTheme: kPaydownDarkTheme,
        themeMode: widget.theme.mode,
        home: LoginScreen(auth: widget.auth, onSuccess: widget.onSessionChange),
      );
    }
    // ApiScope must sit ABOVE MaterialApp: the Navigator MaterialApp creates
    // lives above `home:`, so routes pushed from inside the shell (Settings,
    // Bills, Subscriptions, the unlogged-payments page, ...) would be outside
    // the InheritedWidget if it wrapped HomeShell instead. Widget tests wrap
    // ApiScope outside MaterialApp, which is why this only blew up on device.
    return ApiScope(
      client: client,
      child: MaterialApp(
        title: 'Paydown',
        theme: kPaydownTheme,
        darkTheme: kPaydownDarkTheme,
        themeMode: widget.theme.mode,
        home: HomeShell(theme: widget.theme, onSignOut: () async {
          await widget.auth.clear();
          widget.onSessionChange();
        }),
      ),
    );
  }
}

/// Bottom navigation: the three daily tabs plus More.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.theme, required this.onSignOut});

  final ThemeModeController theme;
  final Future<void> Function() onSignOut;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _tabs = [
    (label: 'Today', icon: Icons.today, body: TodayScreen()),
    (label: 'Plan', icon: Icons.savings, body: PlanScreen()),
    (label: 'Accounts', icon: Icons.account_balance, body: AccountsScreen()),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Paydown'),
          actions: [
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout),
              onPressed: () => widget.onSignOut(),
            ),
          ],
        ),
        body: IndexedStack(index: _tab, children: [
          for (final t in _tabs) t.body,
          MoreScreen(theme: widget.theme),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            for (final t in _tabs)
              NavigationDestination(icon: Icon(t.icon), label: t.label),
            const NavigationDestination(
                icon: Icon(Icons.more_horiz), label: 'More'),
          ],
        ),
      );
}
