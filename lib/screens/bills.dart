import 'package:flutter/material.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

/// Lane C (docs/ANDROID1.md): bills & spending expenses.
///
/// Fetches `GET /api/expenses` plus `GET /api/upcoming?days=31`; upcoming rows
/// drive the paid/due state for the current occurrence of each bill. CRUD via
/// `POST/PUT/DELETE /api/expenses`; mark paid via
/// `POST /api/bills/{id}/paid {due_date}`, unmark via
/// `DELETE /api/bills/{id}/paid/{due_date}`.
class BillsScreen extends StatefulWidget {
  const BillsScreen({super.key});

  @override
  State<BillsScreen> createState() => _BillsScreenState();
}

class _Occurrence {
  _Occurrence(this.date, this.status);

  final String date; // YYYY-MM-DD
  final String status; // expected/due/on_card/paid/target
}

class _BillsScreenState extends State<BillsScreen> {
  late Future<List<dynamic>> _future = _load();

  Map<int, _Occurrence> _occurrences = const {};
  Future<List<dynamic>> _load() async {
    final results = await Future.wait([
      ApiScope.of(context).get('/api/expenses'),
      ApiScope.of(context).get('/api/upcoming?days=31'),
    ]);
    final occurrences = <int, _Occurrence>{};
    for (final row in (results[1] as List)) {
      if (row['kind'] == 'bill') {
        occurrences[row['id'] as int] = _Occurrence(
          row['date'] as String,
          row['status'] as String,
        );
      }
    }
    _occurrences = occurrences;
    return (results[0] as List).toList();
  }

  void _refresh() {
    final future = _load();
    setState(() {
      _future = future;
    });
  }

  Future<void> _mutate(String message, Future<dynamic> Function() action) async {
    try {
      await action();
    } on ApiError catch (e) {
      if (!mounted) return;
      showError(context, e.message);
      return;
    }
    if (!mounted) return;
    toast(context, message);
    _refresh();
  }

  Future<void> _expenseDialog({
    required String kind,
    Map<String, dynamic>? existing,
  }) {
    final name =
        TextEditingController(text: (existing?['name'] as String?) ?? '');
    final amount = TextEditingController(
        text: existing == null
            ? ''
            : ((existing['amount_cents'] as int) / 100.0).toStringAsFixed(2));
    final dueDay = TextEditingController(text: '${existing?['due_day'] ?? ''}');
    var paidFrom = (existing?['paid_from'] as String?) ?? 'cash';
    var active = existing == null ? true : (existing['active'] as int) == 1;
    final isBill = kind == 'bill';
    String? amountError;
    String? dueDayError;
    final screenContext = context;

    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: Text(existing == null
              ? (isBill ? 'Add bill' : 'Add spending')
              : 'Edit ${existing['name']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                      labelText: 'Amount',
                      prefixText: r'$',
                      errorText: amountError),
                ),
                if (isBill)
                  TextField(
                    controller: dueDay,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: 'Due day of month', errorText: dueDayError),
                  ),
                DropdownButtonFormField<String>(
                  initialValue: paidFrom,
                  decoration: const InputDecoration(labelText: 'Paid from'),
                  items: const [
                    DropdownMenuItem(value: 'cash', child: Text('Cash')),
                    DropdownMenuItem(value: 'card', child: Text('Card')),
                  ],
                  onChanged: (v) => setDialog(() => paidFrom = v ?? 'cash'),
                ),
                SwitchListTile(
                  title: const Text('Active'),
                  value: active,
                  onChanged: (v) => setDialog(() => active = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final cents = parseCents(amount.text);
                final day = dueDay.text.trim().isEmpty
                    ? null
                    : int.tryParse(dueDay.text.trim());
                final badDay = isBill &&
                    dueDay.text.trim().isNotEmpty &&
                    (day == null || day < 1 || day > 31);
                if (cents == null || badDay) {
                  setDialog(() {
                    amountError =
                        cents == null ? 'Enter an amount, like 125.00' : null;
                    dueDayError = badDay ? 'Day 1–31' : null;
                  });
                  return;
                }
                final body = <String, dynamic>{
                  'name': name.text.trim(),
                  'amount_cents': cents,
                  'kind': kind,
                  'paid_from': paidFrom,
                  'active': active,
                  if (isBill) 'due_day': day,
                  if (existing?['sort'] != null) 'sort': existing!['sort'],
                  if (existing?['match_text'] != null)
                    'match_text': existing!['match_text'],
                };
                final api = ApiScope.of(screenContext);
                Navigator.pop(dialogContext);
                await _mutate(
                    'Saved',
                    () => existing == null
                        ? api.post('/api/expenses', body)
                        : api.put('/api/expenses/${existing['id']}', body));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteExpense(Map<String, dynamic> expense) {
    final id = expense['id'];
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${expense['name']}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _mutate('Deleted',
                  () => ApiScope.of(context).delete('/api/expenses/$id'));
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _togglePaid(Map<String, dynamic> expense, _Occurrence occ) {
    final id = expense['id'];
    if (occ.status == 'paid') {
      _mutate(
          'Unmarked',
          () =>
              ApiScope.of(context).delete('/api/bills/$id/paid/${occ.date}'));
      return;
    }
    _mutate(
        'Marked paid',
        () => ApiScope.of(context)
            .post('/api/bills/$id/paid', {'due_date': occ.date}));
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Bills'),
            bottom: const TabBar(tabs: [Tab(text: 'Bills'), Tab(text: 'Spending')]),
          ),
          // Builder: DefaultTabController.of needs a context below it. The
          // FAB adds to whichever tab is showing (it used to always add a
          // bill, leaving no way to add spending).
          floatingActionButton: Builder(
            builder: (context) => FloatingActionButton(
              key: const Key('add-bill'),
              tooltip: 'Add',
              onPressed: () => _expenseDialog(
                  kind: DefaultTabController.of(context).index == 1
                      ? 'spending'
                      : 'bill'),
              child: const Icon(Icons.add),
            ),
          ),
          body: FutureBuilder<List<dynamic>>(
            future: _future,
            builder: (context, snap) => AsyncView<List<dynamic>>(
              snapshot: snap,
              onRetry: _refresh,
              builder: (expenses) => TabBarView(children: [
                    _list(expenses, 'bill'),
                    _list(expenses, 'spending'),
                  ]),
            ),
          ),
        ),
      );

  Widget _list(List<dynamic> expenses, String kind) {
    final rows = expenses.where((e) => e['kind'] == kind).toList()
      ..sort((a, b) =>
          (a['sort'] as int? ?? 0).compareTo(b['sort'] as int? ?? 0));
    if (rows.isEmpty) return const Center(child: Text('Nothing here yet'));
    return Refresher(
      onRefresh: () async => _refresh(),
      child: ListView(
        key: Key('bills-list-$kind'),
        children: [for (final e in rows) _row(e as Map<String, dynamic>, kind)],
      ),
    );
  }

  Widget _row(Map<String, dynamic> e, String kind) {
    final occ = _occurrences[e['id'] as int];
    final paid = occ?.status == 'paid';
    final subtitle = <String>[
      if (kind == 'bill') 'Due day ${e['due_day']}',
      'from ${e['paid_from']}',
      if (occ != null) shortDate(occ.date),
    ].join(' · ');
    return ListTile(
      key: Key('expense-${e['id']}-$kind'),
      leading: paid ? const Icon(Icons.check_circle, color: Colors.green) : null,
      title: Text(e['name'] as String),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(money(e['amount_cents'] as int)),
          if (kind == 'bill' && occ != null)
            IconButton(
              key: Key('mark-paid-${e['id']}'),
              tooltip: paid ? 'Unmark paid' : 'Mark paid',
              icon: Icon(paid ? Icons.undo : Icons.check),
              onPressed: () => _togglePaid(e, occ),
            ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'edit' => _expenseDialog(kind: kind, existing: e),
              'delete' => _deleteExpense(e),
              _ => Future<void>.value(),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}
