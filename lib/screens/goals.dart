import 'package:flutter/material.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

/// Goals (docs/ANDROID1.md Lane E): list with target vs set-aside progress
/// and target date, CRUD, and set-aside/use moves
/// (`POST /api/goals/{id}/move {amount_cents, note?}` — a negative amount
/// releases money back to cash, per the backend GoalMoveIn wire shape).
class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key});

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  late Future<List<dynamic>> _future;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Deferred so ApiScope.of(context) runs after initState completes.
    _future = Future(_load);
  }

  Future<List<dynamic>> _load() async =>
      (await ApiScope.of(context).get('/api/goals')) as List<dynamic>;

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

  Future<void> _editDialog(Map<String, dynamic>? row) async {
    final nameCtrl = TextEditingController(text: row?['name'] as String? ?? '');
    final targetCtrl = TextEditingController(
        text: row == null
            ? ''
            : ((row['target_cents'] as num) / 100).toStringAsFixed(2));
    final dateCtrl =
        TextEditingController(text: row?['target_date'] as String? ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(row == null ? 'Add goal' : 'Edit goal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name')),
            TextField(
                controller: targetCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Target')),
            TextField(
                controller: dateCtrl,
                decoration: const InputDecoration(
                    labelText: 'Target date (optional, YYYY-MM-DD)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save goal')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final cents = _parseDollars(targetCtrl.text);
    final date = dateCtrl.text.trim();
    if (name.isEmpty || cents == null || cents <= 0) {
      _fail(ApiError(0, 'Name and a target above zero are required.'));
      return;
    }
    final body = <String, dynamic>{
      'name': name,
      'target_cents': cents,
      'target_date': date.isEmpty ? null : date,
    };
    await _action(
      () => row == null
          ? ApiScope.of(context).post('/api/goals', body)
          : ApiScope.of(context).put('/api/goals/${row['id']}', body),
      row == null ? 'Goal added' : 'Goal saved',
    );
  }

  Future<void> _moveDialog(Map<String, dynamic> goal,
      {required bool setAside}) async {
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(setAside
            ? 'Set aside for ${goal['name']}'
            : 'Use money from ${goal['name']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount')),
            TextField(
                controller: noteCtrl,
                decoration:
                    const InputDecoration(labelText: 'Note (optional)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(setAside ? 'Set aside' : 'Use')),
        ],
      ),
    );
    if (ok != true) return;
    final cents = _parseDollars(amountCtrl.text);
    if (cents == null || cents <= 0) {
      _fail(ApiError(0, 'Enter an amount greater than zero.'));
      return;
    }
    final note = noteCtrl.text.trim();
    await _action(
      () => ApiScope.of(context).post('/api/goals/${goal['id']}/move', {
        'amount_cents': setAside ? cents : -cents,
        'note': note.isEmpty ? null : note,
      }),
      setAside ? 'Set aside' : 'Money released',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Goals')),
      body: Refresher(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<dynamic>>(
        future: _future,
        builder: (context, snap) => AsyncView<List<dynamic>>(
          snapshot: snap,
          onRetry: _reload,
          builder: (goals) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    title: Text(_error!,
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer)),
                    trailing: IconButton(
                      tooltip: 'Dismiss error',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _error = null),
                    ),
                  ),
                ),
              FilledButton.tonal(
                onPressed: () => _editDialog(null),
                child: const Text('Add goal'),
              ),
              const SizedBox(height: 8),
              if (goals.isEmpty)
                const Text('No goals yet — set money aside for car repairs, '
                    'insurance, holidays.'),
              for (final raw in goals) _goalRow(raw as Map<String, dynamic>),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _goalRow(Map<String, dynamic> g) {
    final pct = (g['progress_pct'] as num? ?? 0).clamp(0, 100).toDouble();
    return Card(
      key: ValueKey('goal-${g['id']}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(g['name'] as String,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (g['active'] == false)
                  Text('inactive',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
              ],
            ),
            LinearProgressIndicator(value: pct / 100),
            Text('${money(g['set_aside_cents'] as int)} of '
                '${money(g['target_cents'] as int)}'),
            Text(
              [
                if (g['target_date'] != null)
                  'By ${shortDate(g['target_date'] as String)}',
                if ((g['per_paycheck_cents'] as num? ?? 0) > 0)
                  'Set aside ${money((g['per_paycheck_cents'] as num).toInt())} each paycheck',
                if ((g['monthly_need_cents'] as num? ?? 0) > 0)
                  '${money((g['monthly_need_cents'] as num).toInt())}/month in your budget',
              ].join(' · '),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
            Row(
              children: [
                TextButton(
                  key: ValueKey('set-aside-${g['id']}'),
                  onPressed: () => _moveDialog(g, setAside: true),
                  child: const Text('Set aside'),
                ),
                TextButton(
                  key: ValueKey('use-${g['id']}'),
                  onPressed: () => _moveDialog(g, setAside: false),
                  child: const Text('Use'),
                ),
                TextButton(
                  onPressed: () => _editDialog(g),
                  child: const Text('Edit'),
                ),
                TextButton(
                  key: ValueKey('delete-${g['id']}'),
                  onPressed: () async {
                    if (await _confirm(
                        'Delete goal "${g['name']}"? Its moves are removed too.')) {
                      await _action(
                        () => ApiScope.of(context)
                            .delete('/api/goals/${g['id']}'),
                        'Goal deleted',
                      );
                    }
                  },
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "12.34" -> 1234 cents; null when not a valid amount.
int? _parseDollars(String text) => parseCents(text);
