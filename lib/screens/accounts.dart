import 'dart:async';

import 'package:flutter/material.dart';
import 'package:plaid_flutter/plaid_flutter.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

/// A8: Link tokens for the Android SDK must name the app's package.
const kAndroidPackageName = 'us.snakepit.paydown';

/// Injectable seam around plaid_flutter so widget tests never touch the
/// plugin (A6/A9). The real launcher subscribes to PlaidLink's streams and
/// cancels them in [dispose] — subscriptions never outlive the screen (A8).
abstract class PlaidLinkLauncher {
  void open(String linkToken,
      {required void Function(String publicToken, String institutionName)
          onSuccess});

  void dispose();
}

class PlaidFlutterLauncher implements PlaidLinkLauncher {
  StreamSubscription<LinkSuccess>? _successSub;
  StreamSubscription<LinkExit>? _exitSub;

  @override
  void open(String linkToken,
      {required void Function(String publicToken, String institutionName)
          onSuccess}) {
    _successSub = PlaidLink.onSuccess.listen((success) {
      onSuccess(
          success.publicToken, success.metadata.institution?.name ?? '');
    });
    // onExit: dismiss silently (A8 — log nothing sensitive).
    _exitSub = PlaidLink.onExit.listen((_) {});
    PlaidLink.create(configuration: LinkTokenConfiguration(token: linkToken));
    PlaidLink.open();
  }

  @override
  void dispose() {
    _successSub?.cancel();
    _exitSub?.cancel();
    _successSub = null;
    _exitSub = null;
  }
}

/// Accounts screen (Lane D, docs/ANDROID1.md): cash accounts, cards, Plaid.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key, this.linkLauncher});

  /// Test seam; production constructs [PlaidFlutterLauncher].
  final PlaidLinkLauncher? linkLauncher;

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

typedef _Loaded = ({
  List<dynamic> cash,
  List<dynamic> cards,
  Map<dynamic, dynamic>? plaidStatus,
  List<dynamic> plaidAccounts,
});

class _AccountsScreenState extends State<AccountsScreen> {
  Future<_Loaded>? _future;
  late PlaidLinkLauncher _link;
  _Loaded? _data;
  String? _actionError;
  ApiClient? _client;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _link = widget.linkLauncher ?? PlaidFlutterLauncher();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ApiScope.of uses dependOnInheritedWidgetOfExactType — legal here, not
    // in initState.
    _client ??= ApiScope.of(context);
    if (!_loaded) {
      _loaded = true;
      _future = _load();
    }
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<_Loaded> _load() async {
    final api = _client!;
    final cash = (await api.get('/api/cash-accounts')) as List<dynamic>? ??
        const <dynamic>[];
    final cards = (await api.get('/api/cards')) as List<dynamic>? ??
        const <dynamic>[];
    final status = await api.get('/api/plaid/status');
    final configured = status is Map && status['configured'] == true;
    final plaidAccounts = configured
        ? (await api.get('/api/plaid/accounts')) as List<dynamic>? ??
            const <dynamic>[]
        : const <dynamic>[];
    final loaded = (
      cash: cash,
      cards: cards,
      plaidStatus: status is Map ? status : null,
      plaidAccounts: plaidAccounts,
    );
    if (mounted) setState(() => _data = loaded);
    return loaded;
  }

  Future<void> _reload() async {
    setState(() {
      _actionError = null;
      _future = _load();
    });
    await _future;
  }

  /// Runs a mutation; failures surface as a persistent banner (A4), success
  /// toasts and re-fetches the screen.
  Future<void> _run(Future<dynamic> Function() action, String done) async {
    try {
      await action();
      if (!mounted) return;
      toast(context, done);
      await _reload();
    } on ApiError catch (e) {
      if (mounted) setState(() => _actionError = e.message);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Refresher(
      onRefresh: _reload,
      child: FutureBuilder<_Loaded>(
        future: _future,
        builder: (context, snapshot) => AsyncView<_Loaded>(
        snapshot: snapshot,
        onRetry: _reload,
        builder: (data) {
          final showPlaid =
              data.plaidStatus != null && data.plaidStatus!['configured'] == true;
          return ListView(
            key: const Key('accounts-list'),
            children: [
              if (_actionError != null)
                Material(
                  color: theme.colorScheme.errorContainer,
                  child: ListTile(
                    leading: Icon(Icons.error_outline,
                        color: theme.colorScheme.error),
                    title: Text(_actionError!),
                    trailing: IconButton(
                      tooltip: 'Dismiss error',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _actionError = null),
                    ),
                  ),
                ),
              _sectionHeader(context, 'Cash accounts',
                  trailing: IconButton(
                    key: const Key('cash-add'),
                    tooltip: 'Add cash account',
                    icon: const Icon(Icons.add),
                    onPressed: () => _cashDialog(null),
                  )),
              for (final a in data.cash) _cashCard(a),
              _sectionHeader(context, 'Cards',
                  trailing: IconButton(
                    key: const Key('card-add'),
                    tooltip: 'Add card',
                    icon: const Icon(Icons.add),
                    onPressed: () => _cardAddDialog(),
                  )),
              for (final c in data.cards) _cardCard(c),
              if (showPlaid) ...[
                _sectionHeader(
                  context,
                  'Plaid',
                  trailing: Wrap(spacing: 4, children: [
                    TextButton(
                      key: const Key('plaid-sync'),
                      onPressed: () =>
                          _run(() => ApiScope.of(context).post('/api/plaid/sync'),
                              'Sync started'),
                      child: const Text('Sync now'),
                    ),
                    TextButton(
                      key: const Key('plaid-connect'),
                      onPressed: _connectBank,
                      child: const Text('Connect bank'),
                    ),
                  ]),
                ),
                for (final item
                    in (data.plaidStatus!['items'] as List<dynamic>? ?? const []))
                  _itemCard(item),
                for (final a in data.plaidAccounts) _plaidAccountCard(a),
              ],
              const SizedBox(height: 24),
            ],
          );
        },
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title,
      {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?trailing,
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- cash

  Widget _cashCard(Map<dynamic, dynamic> a) {
    final included = a['include_in_cash'] == true || a['include_in_cash'] == 1;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        title: Text('${a['name']}'),
        subtitle: Text(money((a['balance_cents'] as num?)?.toInt() ?? 0)),
        trailing: SizedBox(
          width: 140,
          child: Row(children: [
            Expanded(
              child: Switch(
                key: Key('cash-include-${a['id']}'),
                value: included,
                onChanged: (v) => _run(
                  () => ApiScope.of(context).put(
                      '/api/cash-accounts/${a['id']}',
                      {
                        'name': a['name'],
                        'balance_cents': a['balance_cents'],
                        'include_in_cash': v,
                      }),
                  'Updated',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _cashDialog(a),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await _confirm(
                    'Delete account', 'Delete "${a['name']}"?')) {
                  await _run(
                      () =>
                          ApiScope.of(context).delete('/api/cash-accounts/${a['id']}'),
                      'Deleted');
                }
              },
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _cashDialog(Map<dynamic, dynamic>? existing) async {
    final name = TextEditingController(text: existing?['name']?.toString());
    final balance = TextEditingController(
        text: existing == null
            ? ''
            : (((existing['balance_cents'] as num?) ?? 0) / 100)
                .toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'Add cash account' : 'Edit cash account'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              key: const Key('cash-name'),
              controller: name,
              decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              key: const Key('cash-balance'),
              controller: balance,
              decoration: const InputDecoration(labelText: 'Balance (\$)'),
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              key: const Key('cash-save'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final cents = parseDollarsToCents(balance.text);
    final body = <String, dynamic>{
      'name': name.text.trim(),
      'balance_cents': ?cents,
      if (existing != null) 'include_in_cash': existing['include_in_cash'],
    };
    await _run(
      () => existing == null
          ? ApiScope.of(context).post('/api/cash-accounts', body)
          : ApiScope.of(context).put('/api/cash-accounts/${existing['id']}',
              body),
      existing == null ? 'Added' : 'Saved',
    );
  }

  // ---------------------------------------------------------------- cards

  Widget _cardCard(Map<dynamic, dynamic> c) {
    final theme = Theme.of(context);
    final synced = c['sync'] == 'plaid';
    final aprOverride = (c['apr_override'] as num?)?.toDouble();
    final apr = aprOverride ?? (c['apr'] as num?)?.toDouble();
    final bankApr = (c['bank_apr'] as num?)?.toDouble();
    final minOverride = (c['min_override_cents'] as num?)?.toInt();
    final min = minOverride ?? (c['min_payment_cents'] as num?)?.toInt() ?? 0;
    final bankMin = (c['bank_min_payment_cents'] as num?)?.toInt();
    final overdue = c['bank_overdue'] != null &&
        c['bank_overdue'] != 0 &&
        c['bank_overdue'] != false;
    final util = (c['utilization_pct'] as num?)?.toDouble();
    final due = c['next_due_date'];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${c['name']}',
                  style: theme.textTheme.titleMedium),
            ),
            if (overdue)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Chip(
                  key: Key('card-overdue-${c['id']}'),
                  label: Text('Overdue',
                      style: TextStyle(
                          color: theme.colorScheme.onError, fontSize: 11)),
                  backgroundColor: theme.colorScheme.error,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _cardEditDialog(c),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await _confirm('Delete card', 'Delete "${c['name']}"?')) {
                  await _run(
                      () => ApiScope.of(context).delete('/api/cards/${c['id']}'),
                      'Deleted');
                }
              },
            ),
          ]),
          Text(money((c['balance_cents'] as num?)?.toInt() ?? 0),
              style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Row(children: [
            Text('APR ${apr == null ? '—' : pct(apr)}'),
            if (aprOverride != null &&
                bankApr != null &&
                bankApr != aprOverride)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text('bank ${pct(bankApr)}',
                    key: Key('card-bank-apr-${c['id']}'),
                    style: TextStyle(color: theme.disabledColor)),
              ),
            const SizedBox(width: 16),
            Text('Min ${money(min)}'),
            if (minOverride != null && bankMin != null && bankMin != minOverride)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text('bank ${money(bankMin)}',
                    style: TextStyle(color: theme.disabledColor)),
              ),
          ]),
          if (due != null) Text('Due ${shortDate('$due')}'),
          if (synced) Text('Synced via Plaid',
              style: TextStyle(color: theme.hintColor, fontSize: 12)),
          if (util != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: LinearProgressIndicator(
                  key: Key('card-util-${c['id']}'),
                  value: (util / 100).clamp(0.0, 1.0),
                ),
              ),
              const SizedBox(width: 8),
              Text('${util.toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall),
            ]),
          ],
        ]),
      ),
    );
  }

  /// Mirrors the web card form (app/static/views/accounts.js):
  /// - synced cards: the bank owns APR/min/balance, so the editable fields
  ///   are OVERRIDES (blank = use the bank). Plaid often sends no APR or a
  ///   \$0 minimum, which is exactly when an override is needed.
  /// - manual cards: edit the card's own balance, APR and minimum.
  Future<void> _cardEditDialog(Map<dynamic, dynamic> c) async {
    final synced = c['sync'] == 'plaid';
    String centsField(Object? v) =>
        v == null ? '' : centsText((v as num).toInt());
    final name = TextEditingController(text: c['name']?.toString());
    final balance = TextEditingController(text: centsField(c['balance_cents']));
    final apr = TextEditingController(
        text: (synced ? c['apr_override'] : c['bank_apr'] ?? c['apr'])
                ?.toString() ??
            '');
    final min = TextEditingController(
        text: centsField(synced
            ? c['min_override_cents']
            : c['bank_min_payment_cents'] ?? c['min_payment_cents']));
    String? error;
    final bankApr = c['apr_source'] == 'unknown'
        ? 'Bank reports no APR.'
        : 'Bank reports ${pct((c['bank_apr'] as num?) ?? 0)}.';
    final bankMin =
        'Bank reports ${money(((c['bank_min_payment_cents'] as num?) ?? 0).toInt())}.';

    final ok = await showDialog<Object>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text('Edit ${c['name']}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  key: const Key('card-edit-name'),
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name')),
              if (!synced)
                TextField(
                    key: const Key('card-edit-balance'),
                    controller: balance,
                    decoration: const InputDecoration(
                        labelText: 'Current balance', prefixText: r'$'),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true)),
              TextField(
                  key: const Key('card-edit-apr'),
                  controller: apr,
                  decoration: InputDecoration(
                      labelText: synced ? 'APR override (%)' : 'APR (%)',
                      hintText: synced ? 'blank = use the bank' : 'e.g. 24.99',
                      helperText: synced ? bankApr : null),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true)),
              TextField(
                  key: const Key('card-edit-min'),
                  controller: min,
                  decoration: InputDecoration(
                      labelText:
                          synced ? 'Minimum override' : 'Minimum payment',
                      prefixText: r'$',
                      hintText: synced ? 'blank = use the bank' : null,
                      helperText: synced ? bankMin : null),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true)),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              if (synced &&
                  (c['apr_override'] != null || c['min_override_cents'] != null))
                TextButton(
                  key: const Key('card-clear-overrides'),
                  onPressed: () => Navigator.pop(context, 'clear'),
                  child: const Text('Clear overrides'),
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                key: const Key('card-edit-save'),
                onPressed: () {
                  final problem = _cardFormProblem(
                      synced: synced,
                      name: name.text,
                      balance: balance.text,
                      apr: apr.text,
                      min: min.text);
                  if (problem != null) {
                    setDialog(() => error = problem);
                    return;
                  }
                  Navigator.pop(context, true);
                },
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok == null || !mounted) return;
    final api = ApiScope.of(context);
    if (ok == 'clear') {
      // FIX5 semantics: explicit nulls clear the overrides.
      await _run(
          () => api.put('/api/cards/${c['id']}', {
                'apr_override': null,
                'min_override_cents': null,
              }),
          'Overrides cleared');
      return;
    }
    if (ok != true) return;
    final body = <String, dynamic>{'name': name.text.trim()};
    if (synced) {
      // Blank = null = use the bank (the server accepts explicit nulls).
      body['apr_override'] = _parseApr(apr.text);
      body['min_override_cents'] = parseCents(min.text);
    } else {
      body['balance_cents'] = parseCents(balance.text);
      body['apr'] = _parseApr(apr.text);
      body['min_payment_cents'] = parseCents(min.text);
    }
    await _run(() => api.put('/api/cards/${c['id']}', body), 'Saved');
  }

  Future<void> _cardAddDialog() async {
    final name = TextEditingController();
    final balance = TextEditingController();
    final apr = TextEditingController();
    final min = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add card'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              key: const Key('card-add-name'),
              controller: name,
              decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              key: const Key('card-add-balance'),
              controller: balance,
              decoration: const InputDecoration(labelText: 'Balance (\$)'),
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true)),
          TextField(
              key: const Key('card-add-apr'),
              controller: apr,
              decoration: const InputDecoration(labelText: 'APR (%)'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true)),
          TextField(
              key: const Key('card-add-min'),
              controller: min,
              decoration: const InputDecoration(labelText: 'Min payment (\$)'),
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              key: const Key('card-add-save'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final body = <String, dynamic>{
      'name': name.text.trim(),
      if (parseDollarsToCents(balance.text) != null)
        'balance_cents': parseDollarsToCents(balance.text),
      'apr': ?_parseApr(apr.text),
      if (parseDollarsToCents(min.text) != null)
        'min_payment_cents': parseDollarsToCents(min.text),
    };
    await _run(
        () => ApiScope.of(context).post('/api/cards', body), 'Card added');
  }

  // ---------------------------------------------------------------- plaid

  Widget _itemCard(Map<dynamic, dynamic> it) {
    final theme = Theme.of(context);
    final errorCode = it['error_code'];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        title: Text('${it['institution_name']}'),
        subtitle: Text(
          [
            '${it['status']}',
            if (errorCode != null) '$errorCode',
            if (it['last_synced_at'] != null)
              'Synced ${shortDate('${it['last_synced_at']}')}',
            'Accounts: ${it['accounts'] ?? 0}',
          ].join(' · '),
          style: errorCode != null ? TextStyle(color: theme.colorScheme.error) : null,
        ),
        isThreeLine: false,
        trailing: IconButton(
          key: Key('plaid-item-delete-${it['id']}'),
          tooltip: 'Unlink bank',
          icon: const Icon(Icons.link_off),
          onPressed: () async {
            if (await _confirm('Remove bank connection',
                'Disconnect ${it['institution_name']} and delete its synced data?')) {
              await _run(
                  () => ApiScope.of(context).delete('/api/plaid/items/${it['id']}'),
                  'Disconnected');
            }
          },
        ),
      ),
    );
  }

  Widget _plaidAccountCard(Map<dynamic, dynamic> a) {
    final linkedTo = a['card_name'] ?? a['cash_account_name'];
    final ignored = a['ignored'] == true || a['ignored'] == 1;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        title: Text(
            '${a['name']}${a['mask'] == null ? '' : ' ••${a['mask']}'}'
            '${ignored ? ' (ignored)' : ''}'),
        subtitle: Text(
            'Linked: ${linkedTo ?? 'unlinked'} · ${a['institution_name']}'),
        trailing: PopupMenuButton<String>(
          key: Key('plaid-account-menu-${a['id']}'),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'link', child: Text('Link…')),
            const PopupMenuItem(value: 'unlink', child: Text('Unlink')),
            PopupMenuItem(
                value: ignored ? 'unignore' : 'ignore',
                child: Text(ignored ? 'Unignore' : 'Ignore')),
          ],
          onSelected: (action) async {
            switch (action) {
              case 'link':
                await _plaidLinkDialog(a);
              case 'unlink':
                await _run(
                    () => ApiScope.of(context)
                        .post('/api/plaid/accounts/${a['id']}/unlink'),
                    'Unlinked');
              case 'ignore':
                await _run(
                    () => ApiScope.of(context).post(
                        '/api/plaid/accounts/${a['id']}/ignore',
                        {'ignored': true}),
                    'Ignored');
              case 'unignore':
                await _run(
                    () => ApiScope.of(context).post(
                        '/api/plaid/accounts/${a['id']}/ignore',
                        {'ignored': false}),
                    'Unignored');
            }
          },
        ),
      ),
    );
  }

  Future<void> _plaidLinkDialog(Map<dynamic, dynamic> account) async {
    final data = _data;
    if (data == null) return;
    final isCredit = account['type'] == 'credit';
    final options = <(String, int)>[
      for (final c in data.cards.cast<Map<dynamic, dynamic>>())
        if (isCredit) ('card', c['id'] as int),
      for (final c in data.cash.cast<Map<dynamic, dynamic>>())
        if (!isCredit) ('cash', c['id'] as int),
    ];
    if (!mounted) return;
    final selected = await showDialog<(String, int)?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Link "${account['name']}"'),
        children: [
          for (final opt in options)
            SimpleDialogOption(
              child: Text(opt.$1 == 'card'
                  ? 'Card: ${_nameOf(data.cards, opt.$2)}'
                  : 'Cash: ${_nameOf(data.cash, opt.$2)}'),
              onPressed: () => Navigator.pop(context, opt),
            ),
          SimpleDialogOption(
            key: const Key('plaid-link-create'),
            child: const Text('Create new automatically'),
            onPressed: () => Navigator.pop(context, ('create', 0)),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final api = ApiScope.of(context);
    await _run(() {
      final (kind, id) = selected;
      return api.post(
        '/api/plaid/accounts/${account['id']}/link',
        switch (kind) {
          'card' => {'card_id': id},
          'cash' => {'cash_account_id': id},
          _ => {'create': true},
        },
      );
    }, 'Linked');
  }

  String _nameOf(List<dynamic> list, int id) {
    for (final row in list) {
      if (row is Map && row['id'] == id) return '${row['name']}';
    }
    return '#$id';
  }

  Future<void> _connectBank() async {
    final api = ApiScope.of(context);
    try {
      final res = await api.post('/api/plaid/link-token',
          {'android_package_name': kAndroidPackageName});
      final token = res is Map ? res['link_token'] : null;
      if (token is! String || token.isEmpty) {
        throw ApiError(500, 'Server returned no link token');
      }
      _link.open(token, onSuccess: (publicToken, institutionName) {
        _run(
          () => api.post('/api/plaid/exchange', {
            'public_token': publicToken,
            'institution_name': institutionName,
          }),
          'Bank connected',
        );
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _actionError = e.message);
    }
  }
}

/// "1,234.56" / "$1234.56" / "12.34" -> cents, or null when blank/invalid.
int? parseDollarsToCents(String input) => parseCents(input);

/// "24.99" / "24.99%" -> 24.99; null when blank or invalid.
double? _parseApr(String input) {
  final t = input.trim().replaceAll('%', '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  return (v == null || v < 0 || v > 100 || v.isNaN) ? null : v;
}

/// Validation shared by the card dialog; null when the form is OK.
String? _cardFormProblem({
  required bool synced,
  required String name,
  required String balance,
  required String apr,
  required String min,
}) {
  if (name.trim().isEmpty) return 'Name is required.';
  if (apr.trim().isNotEmpty && _parseApr(apr) == null) {
    return 'APR must be a number from 0 to 100.';
  }
  if (min.trim().isNotEmpty && parseCents(min) == null) {
    return 'Enter the minimum like 35.00.';
  }
  if (!synced) {
    if (parseCents(balance) == null) return 'Enter the balance like 1234.56.';
    if (_parseApr(apr) == null) return 'APR is required.';
    if (parseCents(min) == null) return 'Minimum payment is required.';
  }
  return null;
}
