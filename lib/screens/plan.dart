import 'package:flutter/material.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

/// Lane B (docs/ANDROID1.md): Plan screen over GET /api/mobile/home.
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key});

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  late Future<void> _future;
  Map<String, dynamic>? _home;
  List<Map<String, dynamic>> _adjustments = const [];
  String _strategy = 'avalanche';
  Object? _error;

  ApiClient? _client;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _client ??= ApiScope.of(context);
    if (!_loaded) {
      _loaded = true;
      _future = _load();
    }
  }

  Future<void> _load() async {
    final client = _client!;
    try {
      final home = await client.get('/api/mobile/home') as Map<String, dynamic>;
      final month = home['month'] as String?;
      List<Map<String, dynamic>> adjustments = const [];
      if (month != null) {
        try {
          final raw = await client.get('/api/adjustments?month=$month');
          if (raw is List) {
            adjustments = raw.whereType<Map<String, dynamic>>().toList();
          }
        } on ApiError {
          adjustments = const []; // adjustments are non-critical
        }
      }
      if (!mounted) return;
      setState(() {
        _home = home;
        _adjustments = adjustments;
        _strategy =
            ((home['settings'] as Map<String, dynamic>?)?['strategy'] as String?) ??
                _strategy;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e); // AsyncView renders the error persistently (A4)
    }
  }

  Future<void> _reload() async {
    setState(() {
      _future = _load();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final client = ApiScope.of(context);
    return AsyncView<void>(
      snapshot: _error != null
          ? AsyncSnapshot<void>.withError(ConnectionState.done, _error!)
          : _home != null
              ? const AsyncSnapshot<void>.withData(ConnectionState.done, null)
              : const AsyncSnapshot<void>.waiting(),
      onRetry: _reload,
      builder: (_) {
        final home = _home!;
        final budget = (home['budget'] as Map<String, dynamic>?) ?? const {};
        final cash = (home['cash'] as Map<String, dynamic>?) ?? const {};
        final projection = (home['projection'] as Map<String, dynamic>?) ?? const {};
        final plan = (home['plan'] as List?) ?? const [];
        return Refresher(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _MonthHeader(home: home, budget: budget),
              const SizedBox(height: 12),
              Text('Plan', style: Theme.of(context).textTheme.titleMedium),
              for (final row in plan.whereType<Map<String, dynamic>>()) _PlanRow(row: row),
              const SizedBox(height: 12),
              _StrategySection(
                projection: projection,
                strategy: _strategy,
                onStrategy: (s) => setState(() => _strategy = s),
              ),
              const SizedBox(height: 12),
              if (cash['is_current_month'] == true)
                FilledButton(
                  onPressed: () => _useSpareCash(context, client),
                  child: const Text('Use spare cash'),
                ),
              const SizedBox(height: 12),
              _AdjustmentsSection(
                adjustments: _adjustments,
                onAdd: _addAdjustment,
                onDelete: _deleteAdjustment,
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _useSpareCash(BuildContext context, ApiClient client) async {
    final home = _home!;
    final month = home['month'] as String;
    // The server sweeps cash.spare_cents (cash above floor + reserve), which
    // is NOT Safe-to-Spend; show and validate against the same number.
    final spare = _cents(
        (home['cash'] as Map<String, dynamic>?) ?? const {}, 'spare_cents');
    if (spare <= 0) {
      showError(context, 'No spare cash above your floor and reserve.');
      return;
    }
    final result = await showDialog<(int, bool)>(
      context: context,
      builder: (context) => _UseCashDialog(spareCents: spare),
    );
    if (result == null) return;
    final (amount, useBody) = result;
    try {
      await client.post(
          '/api/month/$month/use-cash', useBody ? {'amount_cents': amount} : null);
    } on ApiError catch (e) {
      if (!context.mounted) return;
      showError(context, e.message);
      return;
    }
    if (!context.mounted) return;
    toast(context, 'Applied ${money(amount)} to debt');
    await _reload();
  }

  Future<void> _addAdjustment(String name, int cents) async {
    final client = ApiScope.of(context);
    final month = _home!['month'] as String;
    try {
      await client.post('/api/adjustments', {
        'month': month,
        'name': name,
        'amount_cents': cents,
      });
    } on ApiError catch (e) {
      if (mounted) showError(context, e.message);
      return;
    }
    await _reload();
  }

  Future<void> _deleteAdjustment(int id) async {
    try {
      await ApiScope.of(context).delete('/api/adjustments/$id');
    } on ApiError catch (e) {
      if (mounted) showError(context, e.message);
      return;
    }
    await _reload();
  }
}

int _cents(Map<String, dynamic> m, String key) => (m[key] as num?)?.toInt() ?? 0;

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.home, required this.budget});

  final Map<String, dynamic> home;
  final Map<String, dynamic> budget;

  @override
  Widget build(BuildContext context) {
    final paid = (home['paid_total_cents'] as num?)?.toInt() ?? 0;
    final recommended = (home['recommended_total_cents'] as num?)?.toInt() ?? 0;
    // A7: recurring extra is the recurring budget minus minimums — never the
    // one-off-inflated total extra.
    final recurringExtra =
        _cents(budget, 'recurring_debt_budget_cents') - _cents(budget, 'minimums_total_cents');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(monthLabel((home['month'] as String?) ?? ''),
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _Tile('Paid', '${money(paid)} of ${money(recommended)}'),
                _Tile('Debt budget', money(_cents(budget, 'debt_budget_cents'))),
                _Tile(
                    'Recurring budget', money(_cents(budget, 'recurring_debt_budget_cents'))),
                _Tile('Minimums', money(_cents(budget, 'minimums_total_cents'))),
                _Tile('Recurring extra', money(recurringExtra)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
      );
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final paid = _cents(row, 'paid_cents');
    final recommended = _cents(row, 'recommended_cents');
    final remaining = _cents(row, 'remaining_cents');
    final minRemaining = _cents(row, 'min_remaining_cents');
    final extra = remaining - minRemaining;
    final progress = recommended > 0 ? (paid / recommended).clamp(0.0, 1.0) : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text((row['name'] as String?) ?? '',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (row['bank_overdue'] == true)
                  Chip(
                    label: const Text('Overdue'),
                    backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 6),
            Text('${money(paid)} of ${money(recommended)}'),
            Text(
                'Remaining ${money(remaining)} '
                '(min ${money(minRemaining)} + extra ${money(extra)})',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _StrategySection extends StatelessWidget {
  const _StrategySection({
    required this.projection,
    required this.strategy,
    required this.onStrategy,
  });

  final Map<String, dynamic> projection;
  final String strategy;
  final ValueChanged<String> onStrategy;

  @override
  Widget build(BuildContext context) {
    final p = (projection[strategy] as Map<String, dynamic>?) ?? const {};
    final savedRaw = projection['interest_saved_cents'];
    final never = projection['minimums_only_never'] == true;
    // A7: never render $0 saved when minimums alone would never pay it off.
    final savedText =
        (savedRaw == null || (savedRaw is num && savedRaw.toInt() == 0)) && never
            ? 'minimums never pay this off'
            : money(_cents(projection, 'interest_saved_cents'));
    final schedule = ((p['schedule'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Strategy', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'avalanche', label: Text('Avalanche')),
                ButtonSegment(value: 'snowball', label: Text('Snowball')),
                ButtonSegment(value: 'custom', label: Text('Custom')),
              ],
              selected: {strategy},
              onSelectionChanged: (s) => onStrategy(s.first),
            ),
            const SizedBox(height: 8),
            InfoRow(
                title: 'Payoff',
                subtitle:
                    '${p['months'] ?? '?'} months${p['debt_free_month'] == null ? '' : ' (${p['debt_free_month']})'}'),
            InfoRow(title: 'Total interest', subtitle: money(_cents(p, 'total_interest_cents'))),
            InfoRow(title: 'Interest saved vs minimums', subtitle: savedText),
            const SizedBox(height: 8),
            Text('Schedule', style: Theme.of(context).textTheme.titleSmall),
            for (final m in schedule.take(12))
              InfoRow(
                title: m['month'] as String? ?? '',
                subtitle:
                    'paid ${money(_sumPayments(m))} · balance ${money(_cents(m, 'total_balance_cents'))}',
              ),
            if (schedule.length > 12)
              const Padding(
                padding: EdgeInsets.only(left: 16),
                child: Text('…'),
              ),
          ],
        ),
      ),
    );
  }

  int _sumPayments(Map<String, dynamic> m) {
    final payments = (m['payments'] as Map?) ?? const {};
    return payments.values.fold<int>(0, (a, v) => a + ((v as num?)?.toInt() ?? 0));
  }
}

class _UseCashDialog extends StatefulWidget {
  const _UseCashDialog({required this.spareCents});

  final int spareCents;

  @override
  State<_UseCashDialog> createState() => _UseCashDialogState();
}

class _UseCashDialogState extends State<_UseCashDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _customCents {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return null;
    return parseCents(raw);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Use spare cash'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Spare: ${money(widget.spareCents)}'),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Custom amount',
                prefixText: r'$',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, (widget.spareCents, false)),
            child: Text('Spare all (${money(widget.spareCents)})'),
          ),
          FilledButton(
            onPressed: _customCents == null || _customCents! <= 0
                ? null
                : () => Navigator.pop(context, (_customCents!, true)),
            child: const Text('Apply'),
          ),
        ],
      );
}

class _AdjustmentsSection extends StatelessWidget {
  const _AdjustmentsSection({
    required this.adjustments,
    required this.onAdd,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> adjustments;
  final Future<void> Function(String name, int cents) onAdd;
  final Future<void> Function(int id) onDelete;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Bonus adjustments',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(
                    onPressed: () => _showAddDialog(context),
                    icon: const Icon(Icons.add),
                    tooltip: 'Add adjustment',
                  ),
                ],
              ),
              if (adjustments.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text('None this month'),
                ),
              for (final a in adjustments)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text((a['name'] as String?) ?? ''),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(money(_cents(a, 'amount_cents'))),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                        onPressed: () {
                          final id = (a['id'] as num?)?.toInt();
                          if (id != null) onDelete(id);
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );

  Future<void> _showAddDialog(BuildContext context) async {
    final nameController = TextEditingController();
    final amountController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add bonus'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: amountController,
              decoration: const InputDecoration(
                  labelText: 'Amount', prefixText: r'$'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameController.text.trim();
    final cents = parseCents(amountController.text) ?? 0;
    if (name.isEmpty || cents <= 0) return;
    await onAdd(name, cents);
  }
}
