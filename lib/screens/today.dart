import 'package:flutter/material.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

/// Lane A (docs/ANDROID1.md): Today screen. One fetch — GET /api/mobile/home.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  late Future<Map<String, dynamic>> _future;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _future = _fetch();
    }
  }

  Future<Map<String, dynamic>> _fetch() async {
    final res = await ApiScope.of(context).get('/api/mobile/home');
    return (res as Map).cast<String, dynamic>();
  }

  Future<void> _refresh() async {
    final future = _fetch();
    setState(() => _future = future);
    await future;
  }

  Future<void> _openUnlogged() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const UnloggedCardPaymentsPage()),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snap) => AsyncView<Map<String, dynamic>>(
        snapshot: snap,
        onRetry: _refresh,
        builder: (home) {
          final sts = (home['safe_to_spend'] as Map).cast<String, dynamic>();
          final reminders = ((home['reminders'] as Map)['items'] as List)
              .cast<Map>();
          final upcoming = (home['upcoming'] as List).cast<Map>();
          final unloggedCount =
              (sts['unlogged_card_payment_count'] as num?)?.toInt() ?? 0;
          return Refresher(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _HeroCard(
                  sts: sts,
                  onTap: () => _showSafeToSpend(context, sts),
                ),
                if (unloggedCount > 0) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: _openUnlogged,
                    child: Text(
                      'Log $unloggedCount card payment${unloggedCount == 1 ? '' : 's'} from your bank',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'Reminders',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Card(
                  child: Column(
                    children: [
                      for (final r in reminders)
                        ListTile(
                          leading: Text(shortDate(r['date'] as String)),
                          title: Text(r['name'] as String),
                          trailing: Text(money(r['amount_cents'] as int)),
                          tileColor:
                              (r['overdue'] as bool? ?? false) ||
                                  r['note'] != null
                              ? Theme.of(context).colorScheme.errorContainer
                                    .withValues(alpha: 0.4)
                              : null,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Upcoming',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                for (final g in _groupByDate(upcoming))
                  _UpcomingDay(date: g.date, rows: g.rows),
              ],
            ),
          );
        },
      ),
    );
  }
}

void _showSafeToSpend(BuildContext context, Map<String, dynamic> sts) {
  showDialog<void>(
    context: context,
    builder: (_) => SafeToSpendDialog(sts: sts),
  );
}

class _Group {
  _Group(this.date, this.rows);
  final String date;
  final List<Map<String, dynamic>> rows;
}

List<_Group> _groupByDate(List<Map> rows) {
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    groups
        .putIfAbsent(r['date'] as String, () => [])
        .add(r.cast<String, dynamic>());
  }
  return [for (final e in groups.entries) _Group(e.key, e.value)];
}

const _statusColors = <String, Color>{
  'expected': Colors.grey,
  'due': Colors.orange,
  'on_card': Colors.blue,
  'paid': Colors.green,
  'target': Colors.purple,
};

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.sts, required this.onTap});

  final Map<String, dynamic> sts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Safe to spend',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              money(sts['safe_to_spend_cents'] as int),
              style: Theme.of(context).textTheme.displaySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
            Text(
              '${money(sts['per_day_cents'] as int)}/day · ${sts['days_until']} days',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}

class SafeToSpendDialog extends StatelessWidget {
  const SafeToSpendDialog({super.key, required this.sts});

  final Map<String, dynamic> sts;

  @override
  Widget build(BuildContext context) {
    final obligations = (sts['obligations'] as List? ?? const []).cast<Map>();
    final warnings = (sts['warnings'] as List? ?? const []).cast<Map>();
    return AlertDialog(
      title: const Text('Safe to spend'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            InfoRow(
              title: 'Cash',
              trailing: Text(money(sts['cash_total_cents'] as int)),
            ),
            InfoRow(
              title: 'Pending out',
              trailing: Text(money(sts['pending_out_cents'] as int)),
            ),
            InfoRow(
              title: 'Obligations',
              trailing: Text(money(sts['obligations_total_cents'] as int)),
            ),
            for (final o in obligations)
              ListTile(
                dense: true,
                title: Text(o['name'] as String),
                subtitle: o['date'] == null
                    ? null
                    : Text(shortDate(o['date'] as String)),
                trailing: Text(money(o['amount_cents'] as int)),
              ),
            // Informational only (A7): planned extra is not subtracted
            // again in the waterfall above.
            InfoRow(
              title: 'Planned extra',
              trailing: Text(money(sts['planned_extra_cents'] as int)),
            ),
            for (final w in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  w['message'] as String,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _UpcomingDay extends StatelessWidget {
  const _UpcomingDay({required this.date, required this.rows});

  final String date;
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 4),
      Text(shortDate(date), style: Theme.of(context).textTheme.titleSmall),
      Card(
        child: Column(
          children: [
            for (final r in rows)
              ListTile(
                leading: _StatusChip(status: r['status'] as String),
                title: Text(r['name'] as String),
                trailing: r['kind'] == 'card'
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Min ${money(r['min_remaining_cents'] as int)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          // Like the web app: no "+$0.00 extra" noise.
                          if (((r['extra_remaining_cents'] as num?) ?? 0) > 0)
                            Text(
                              'Extra ${money(r['extra_remaining_cents'] as int)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                            ),
                        ],
                      )
                    : Text(money(r['amount_cents'] as int)),
              ),
          ],
        ),
      ),
    ],
  );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = _statusColors[status] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Unlogged card payments flow: GET /api/card-payments/unlogged, then
/// log/dismiss per row or log-all. TodayScreen re-fetches on pop.
class UnloggedCardPaymentsPage extends StatefulWidget {
  const UnloggedCardPaymentsPage({super.key});

  @override
  State<UnloggedCardPaymentsPage> createState() =>
      _UnloggedCardPaymentsPageState();
}

class _UnloggedCardPaymentsPageState extends State<UnloggedCardPaymentsPage> {
  late Future<List<Map<String, dynamic>>> _future;
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _started = false;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _future = _fetch();
    }
  }

  Future<List<Map<String, dynamic>>> _fetch() async {
    final res = await ApiScope.of(context).get('/api/card-payments/unlogged');
    return ((res as List?) ?? const [])
        .cast<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  /// Runs one mutation, then re-reads the list from the server. The server
  /// is the source of truth: log-all answers {logged, linked} (no rows), and
  /// guessing locally which rows went away left logged payments on screen.
  Future<void> _act(String path, String success) async {
    if (_busy) return; // no duplicate POSTs from repeated taps
    final api = ApiScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.post(path);
      final rows = await _fetch();
      if (!mounted) return;
      setState(() => _rows = rows);
      toast(context, success);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unlogged card payments')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            final err = snap.error;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  err is ApiError ? err.message : '$err',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          _rows ??= snap.data!;
          return _buildBody(_rows!);
        },
      ),
    );
  }

  Widget _buildBody(List<Map<String, dynamic>> rows) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_error != null) ...[
          Material(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (_busy) const LinearProgressIndicator(),
        for (final r in rows)
          Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(r['card_name'] as String? ?? 'Card payment'),
                  subtitle: r['date'] == null
                      ? null
                      : Text(shortDate(r['date'] as String)),
                  trailing: Text(money((r['amount_cents'] as num).toInt())),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy
                              ? null
                              : () => _act(
                                  '/api/card-payments/${r['transaction_id']}/log',
                                  'Payment logged',
                                ),
                          child: const Text('Log'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _act(
                                  '/api/card-payments/${r['transaction_id']}/dismiss',
                                  'Dismissed',
                                ),
                          child: const Text('Dismiss'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        if (rows.isNotEmpty)
          FilledButton(
            onPressed: _busy
                ? null
                : () => _act(
                    '/api/card-payments/log-all',
                    'Card payments logged',
                  ),
            child: const Text('Log all'),
          ),
        if (rows.isEmpty) const Center(child: Text('Nothing to log')),
      ],
    );
  }
}
