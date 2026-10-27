import 'package:flutter/material.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

/// Lane F (docs/ANDROID1.md). Debt trend + spending baseline, chart-free.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  late Future<(Map<String, dynamic>, Map<String, dynamic>)> _future;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ApiScope.of uses dependOnInheritedWidgetOfExactType, illegal during
    // initState; defer the first load to didChangeDependencies.
    if (!_started) {
      _started = true;
      _future = _load();
    }
  }

  Future<(Map<String, dynamic>, Map<String, dynamic>)> _load() async {
    final client = ApiScope.of(context);
    final results = await Future.wait([
      client.get('/api/insights/debt-trend'),
      client.get('/api/insights/spending'),
    ]);
    return (
      (results[0] as Map? ?? const {}).cast<String, dynamic>(),
      (results[1] as Map? ?? const {}).cast<String, dynamic>(),
    );
  }

  void _retry() => setState(() {
      _future = _load();
    });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Insights')),
        body: FutureBuilder<(Map<String, dynamic>, Map<String, dynamic>)>(
          future: _future,
          builder: (context, snap) => AsyncView<
              (Map<String, dynamic>, Map<String, dynamic>)>(
            snapshot: snap,
            onRetry: _retry,
            builder: (data) => Refresher(
              onRefresh: () async {
                _retry();
                await _future;
              },
              child: _InsightsBody(trend: data.$1, spending: data.$2),
            ),
          ),
        ),
      );
}

class _InsightsBody extends StatelessWidget {
  const _InsightsBody({required this.trend, required this.spending});

  final Map<String, dynamic> trend;
  final Map<String, dynamic> spending;

  List<Map<String, dynamic>> get _months {
    final raw = (trend['months'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    // Partial months before bank history would read as "\$0 change"; drop
    // them. Keep the trailing current month (tagged partial in the UI).
    return [
      for (var i = 0; i < raw.length; i++)
        if (raw[i]['partial'] != true || i == raw.length - 1) raw[i],
    ];
  }

  String? get _headline {
    final nonPartial = _months.where((m) => m['partial'] != true).toList();
    if (nonPartial.isEmpty) return null;
    return nonPartial.last['month'] as String;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final months = _months;
    final headline = _headline;
    final cats = (spending['categories'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final suggestions = (spending['suggestions'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (headline != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Debt trend — ${monthLabel(headline)}',
              style: theme.textTheme.titleLarge,
            ),
          ),
        if (months.isNotEmpty) _DebtTrendTable(months: months),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Everyday spending', style: theme.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Monthly average over ${(spending['months_used'] as List? ?? const []).join(', ')}',
            style: theme.textTheme.bodySmall,
          ),
        ),
        InfoRow(
          title: 'Total monthly average',
          trailing: Text(money(_asInt(spending['total_monthly_avg_cents']))),
        ),
        InfoRow(
          title: 'Budgeted spending',
          trailing: Text(money(_asInt(spending['budget_spending_cents']))),
        ),
        InfoRow(
          title: 'Gap',
          trailing: Text(
            money(_asInt(spending['gap_cents'])),
            style: TextStyle(
              color: _asInt(spending['gap_cents']) > 0
                  ? theme.colorScheme.error
                  : null,
            ),
          ),
        ),
        ...cats.map((c) => InfoRow(
              title: (c['label'] ?? c['category'] ?? '?') as String,
              subtitle: c['note'] as String?,
              trailing: Text(money(_asInt(c['monthly_avg_cents']))),
            )),
        if (suggestions.isNotEmpty) ...[
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Suggestions', style: theme.textTheme.titleLarge),
          ),
          _SuggestionChecklist(suggestions: suggestions),
        ],
      ],
    );
  }
}

class _DebtTrendTable extends StatelessWidget {
  const _DebtTrendTable({required this.months});

  final List<Map<String, dynamic>> months;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(String text, {bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Text(
            text,
            style: TextStyle(
              fontWeight: strong ? FontWeight.bold : null,
              color: color,
            ),
          ),
        );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 24,
        columns: const [
          DataColumn(label: Text('Month')),
          DataColumn(label: Text('Charges'), numeric: true),
          DataColumn(label: Text('Payments'), numeric: true),
          DataColumn(label: Text('Refunds'), numeric: true),
          DataColumn(label: Text('Interest'), numeric: true),
          DataColumn(label: Text('Fees'), numeric: true),
          DataColumn(label: Text('Net'), numeric: true),
        ],
        rows: [
          for (final m in months)
            DataRow(cells: [
              DataCell(Text(
                monthLabel(m['month'] as String) +
                    (m['partial'] == true ? ' (partial)' : ''),
              )),
              DataCell(cell(money(_asInt(m['charges_cents'])))),
              DataCell(cell(money(_asInt(m['payments_cents'])))),
              DataCell(cell(money(_asInt(m['refunds_cents'])))),
              DataCell(cell(money(_asInt(m['interest_cents'])))),
              DataCell(cell(money(_asInt(m['fees_cents'])))),
              DataCell(cell(
                money(_asInt(m['net_change_cents'])),
                strong: true,
                // Positive net = card debt went UP (bad); negative = paid
                // down (good). Zero stays neutral.
                color: switch (_asInt(m['net_change_cents'])) {
                  > 0 => theme.colorScheme.error,
                  < 0 => theme.brightness == Brightness.dark
                      ? Colors.green.shade300
                      : Colors.green.shade700,
                  _ => null,
                },
              )),
            ]),
        ],
      ),
    );
  }
}

/// Suggestions checklist (only rendered when the payload carries
/// `suggestions`). Add posts a spending expense; the entry disappears.
class _SuggestionChecklist extends StatefulWidget {
  const _SuggestionChecklist({required this.suggestions});

  final List<Map<String, dynamic>> suggestions;

  @override
  State<_SuggestionChecklist> createState() => _SuggestionChecklistState();
}

class _SuggestionChecklistState extends State<_SuggestionChecklist> {
  final Set<int> _busy = {};

  Future<void> _add(Map<String, dynamic> s, int index) async {
    setState(() => _busy.add(index));
    final name =
        (s['name'] ?? s['label'] ?? s['category'] ?? 'Spending').toString();
    final amount =
        _asInt(s['monthly_avg_cents'] ?? s['amount_cents'] ?? s['value_cents']);
    try {
      await ApiScope.of(context).post('/api/expenses',
          {'name': name, 'amount_cents': amount, 'kind': 'spending'});
      if (!mounted) return;
      toast(context, 'Added $name');
      setState(() => _busy.remove(index));
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(index));
      showError(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (var i = 0; i < widget.suggestions.length; i++)
            CheckboxListTile(
              value: false,
              onChanged: _busy.contains(i)
                  ? null
                  : (_) => _add(widget.suggestions[i], i),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                (widget.suggestions[i]['name'] ??
                        widget.suggestions[i]['label'] ??
                        widget.suggestions[i]['category'] ??
                        '?')
                    .toString(),
              ),
              subtitle: widget.suggestions[i]['note'] == null
                  ? null
                  : Text(widget.suggestions[i]['note'] as String),
              secondary: Text(
                money(_asInt(widget.suggestions[i]['monthly_avg_cents'] ??
                    widget.suggestions[i]['amount_cents'])),
              ),
            ),
        ],
      );
}

int _asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
