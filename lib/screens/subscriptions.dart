import 'package:flutter/material.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

const _cycleLabels = {
  'weekly': 'wk',
  'monthly': 'mo',
  'quarterly': 'qtr',
  'yearly': 'yr',
};

/// Subscriptions (docs/ANDROID1.md Lane E): active list sorted by
/// next_renewal with a totals tile, cancelled under an expansion tile, CRUD
/// + cancel/reactivate/delete, and bank-detected suggestions ("Detected").
class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  late Future<SubsData> _future;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Deferred so ApiScope.of(context) runs after initState completes.
    _future = Future(_load);
  }

  Future<SubsData> _load() async {
    final client = ApiScope.of(context);
    final data = await client.get('/api/subscriptions') as Map<String, dynamic>;
    // Suggestions are advisory; a failure there must not blank the screen.
    final suggestions =
        await client.get('/api/subscriptions/suggestions').catchError(
              (Object _) => <dynamic>[],
            );
    return SubsData(data, suggestions as List<dynamic>);
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  void _fail(Object e) {
    if (!mounted) return; // the request can outlive the route
    setState(() => _error = e is ApiError ? e.message : '$e');
  }

  Future<void> _action(Future<dynamic> Function() run, String success) async {
    try {
      await run();
      if (!mounted) return;
      setState(() => _error = null);
      toast(context, success);
      _reload();
    } on ApiError catch (e) {
      _fail(e);
    }
  }

  Future<bool> _confirm(String message) =>
      showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ).then((v) => v ?? false);

  Future<void> _editDialog(Map<String, dynamic>? row,
      {Map<String, dynamic>? prefill}) async {
    final r = prefill ?? row ?? const {};
    final nameCtrl = TextEditingController(text: (r['name'] ?? '') as String);
    final amountCtrl = TextEditingController(
        text: r['amount_cents'] == null
            ? ''
            : ((r['amount_cents'] as num) / 100).toStringAsFixed(2));
    final dateCtrl =
        TextEditingController(text: (r['next_date'] ?? '') as String);
    final matchCtrl =
        TextEditingController(text: (r['match_text'] ?? '') as String);
    var cycle = (r['cycle'] ?? 'monthly') as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(row == null ? 'Add subscription' : 'Edit subscription'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Name')),
                TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'Amount per charge')),
                DropdownButtonFormField<String>(
                  initialValue: cycle,
                  decoration: const InputDecoration(labelText: 'Billed'),
                  items: _cycleLabels.keys
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) =>
                      setDialogState(() => cycle = v ?? 'monthly'),
                ),
                TextField(
                    controller: dateCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Next charge (YYYY-MM-DD)')),
                TextField(
                    controller: matchCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Bank description contains (optional)')),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final cents = _parseDollars(amountCtrl.text);
    final next = dateCtrl.text.trim();
    final match = matchCtrl.text.trim().toLowerCase();
    if (name.isEmpty || cents == null || next.isEmpty) {
      _fail(ApiError(0, 'Name, amount and next charge date are required.'));
      return;
    }
    final body = <String, dynamic>{
      'name': name,
      'amount_cents': cents,
      'cycle': cycle,
      'next_date': next,
      'match_text': match.isEmpty ? null : match,
    };
    await _action(
      () => row == null
          ? ApiScope.of(context).post('/api/subscriptions', body)
          : ApiScope.of(context).put('/api/subscriptions/${row['id']}', body),
      row == null ? 'Subscription added' : 'Subscription saved',
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = ApiScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Subscriptions')),
      body: Refresher(
        onRefresh: () async => _reload(),
        child: FutureBuilder<SubsData>(
        future: _future,
        builder: (context, snap) => AsyncView<SubsData>(
          snapshot: snap,
          onRetry: _reload,
          builder: (data) {
            final totals = data.subs['totals'] as Map<String, dynamic>;
            final active = data.subs['active'] as List<dynamic>;
            final cancelled = data.subs['cancelled'] as List<dynamic>;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      title: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer)),
                      trailing: IconButton(
                        tooltip: 'Dismiss error',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _error = null),
                      ),
                    ),
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _stat(
                            'Per month', money(totals['monthly_cents'] as int)),
                        _stat(
                            'Per year', money(totals['annual_cents'] as int)),
                        _stat('Active', '${totals['active_count']}'),
                      ],
                    ),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => _editDialog(null),
                  child: const Text('Add subscription'),
                ),
                const SizedBox(height: 8),
                if (active.isEmpty)
                  const Text('None yet — add one, or connect a bank and '
                      'Paydown will look for them.'),
                for (final s in active) _activeRow(client, s),
                if (data.suggestions.isNotEmpty)
                  _suggestionsTile(client, data.suggestions),
                if (cancelled.isNotEmpty)
                  ExpansionTile(
                    title: Text('Cancelled (${cancelled.length})'),
                    children: [
                      for (final s in cancelled) _cancelledRow(client, s),
                    ],
                  ),
              ],
            );
          },
        ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
        ],
      );

  Widget _activeRow(ApiClient client, Map<String, dynamic> s) {
    final soon = (s['days_until'] as num? ?? 999) <= 7;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return ListTile(
      key: ValueKey('sub-${s['id']}'),
      title: Text('${s['name']} · ${s['cycle']}'),
      subtitle: Text(
        'Renews ${shortDate(s['next_renewal'] as String)} '
        '(${s['days_until']} days)'
        '${s['note'] == null ? '' : ' · ${s['note']}'}',
        style: TextStyle(
            color: soon ? Theme.of(context).colorScheme.primary : null),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${money(s['amount_cents'] as int)}/${_cycleLabels[s['cycle']]}'
            '${s['cycle'] == 'monthly' ? '' : ' · ${money(s['monthly_cents'] as int)}/mo'}',
          ),
          PopupMenuButton<String>(
            key: ValueKey('sub-menu-${s['id']}'),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'cancel', child: Text('Cancel sub')),
            ],
            onSelected: (action) {
              if (action == 'edit') {
                _editDialog(s);
                return;
              }
              _confirm('Mark "${s['name']}" cancelled? It leaves your plan '
                      'and frees ${money(s['monthly_cents'] as int)}/month. '
                      'This only updates Paydown; cancel the real '
                      'subscription with the company.')
                  .then((yes) {
                if (yes) {
                  _action(
                    () => client.post('/api/subscriptions/${s['id']}/cancel',
                        {'cancelled_on': today}),
                    'Subscription cancelled',
                  );
                }
              });
            },
          ),
        ],
      ),
      onTap: () => _editDialog(s),
    );
  }

  Widget _cancelledRow(ApiClient client, Map<String, dynamic> s) => ListTile(
        key: ValueKey('cancelled-${s['id']}'),
        title: Text(s['name'] as String),
        subtitle: Text(s['cancelled_on'] == null
            ? 'cancelled'
            : 'cancelled ${shortDate(s['cancelled_on'] as String)}'),
        trailing: Text(
            '${money(s['amount_cents'] as int)}/${_cycleLabels[s['cycle']]}'),
        onTap: () async {
          if (await _confirm('Reactivate "${s['name']}"?')) {
            await _action(
              () => client.post('/api/subscriptions/${s['id']}/reactivate'),
              'Subscription reactivated',
            );
          }
        },
      );

  Widget _suggestionsTile(ApiClient client, List<dynamic> suggestions) =>
      ExpansionTile(
        key: const ValueKey('suggestions'),
        initiallyExpanded: true,
        title: Text('Detected (${suggestions.length})'),
        subtitle: const Text('Found in your transactions'),
        children: [
          for (final raw in suggestions) _suggestionRow(client, raw),
        ],
      );

  Widget _suggestionRow(ApiClient client, Map<String, dynamic> s) => ListTile(
        key: ValueKey('suggestion-${s['key']}'),
        title: Text('${s['name']} · ${s['cycle']}'),
        subtitle: Text(_suggestionSubtitle(s)),
        trailing:
            Text('${money(s['amount_cents'] as int)}/${_cycleLabels[s['cycle']]}'),
        onTap: () => _suggestionActions(client, s),
      );

  String _suggestionSubtitle(Map<String, dynamic> s) {
    final bill = s['bill_id'] == null
        ? ''
        : ' · matches your bill "${s['bill_name']}"';
    return '${s['occurrences']} charges, '
        'last ${shortDate(s['last_date'] as String)}$bill';
  }

  Future<void> _suggestionActions(ApiClient client, Map<String, dynamic> s) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s['bill_id'] != null)
              ListTile(
                key: const ValueKey('convert-bill'),
                leading: const Icon(Icons.sync_alt),
                title: Text('Convert bill "${s['bill_name']}"'),
                onTap: () {
                  Navigator.pop(context);
                  _action(
                    () => client
                        .post('/api/subscriptions/from-expense/${s['bill_id']}'),
                    'Bill converted to subscription',
                  );
                },
              )
            else
              ListTile(
                key: const ValueKey('add-suggestion'),
                leading: const Icon(Icons.add),
                title: const Text('Add as subscription'),
                onTap: () {
                  Navigator.pop(context);
                  _editDialog(null, prefill: s);
                },
              ),
            ListTile(
              key: const ValueKey('dismiss-suggestion'),
              leading: const Icon(Icons.visibility_off),
              title: const Text('Dismiss'),
              onTap: () {
                Navigator.pop(context);
                _action(
                  () => client.post('/api/subscriptions/suggestions/dismiss',
                      {'key': s['key']}),
                  'Suggestion dismissed',
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class SubsData {
  SubsData(this.subs, this.suggestions);

  final Map<String, dynamic> subs;
  final List<dynamic> suggestions;
}

/// "12.34" -> 1234 cents; null when not a valid non-negative amount.
int? _parseDollars(String text) => parseCents(text);
