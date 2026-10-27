import 'package:flutter/material.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

/// Lane C (docs/ANDROID1.md): logged card payments by month.
///
/// `GET /api/payments?month=` with a month picker, `POST /api/payments
/// {card_id, amount_cents, month, note?}`, `DELETE /api/payments/{id}`.
/// Card names come from `GET /api/cards`; rows group by card.
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  late String _month;
  late Future<List<dynamic>> _future = _load();

  List<dynamic> _cards = const [];

  _PaymentsScreenState() {
    final now = DateTime.now();
    _month =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
  }

  Future<List<dynamic>> _load() async {
    final results = await Future.wait([
      ApiScope.of(context).get('/api/payments?month=$_month'),
      ApiScope.of(context).get('/api/cards'),
    ]);
    _cards = (results[1] as List).toList();
    return (results[0] as List).toList();
  }

  void _refresh() {
    final future = _load();
    setState(() {
      _future = future;
    });
  }

  void _setMonth(String month) {
    final future = _load();
    setState(() {
      _month = month;
      _future = future;
    });
  }

  void _shiftMonth(int delta) {
    final (y, m) = (int.parse(_month.substring(0, 4)), int.parse(_month.substring(5)));
    final d = DateTime(y, m + delta);
    _setMonth(
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}');
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(
          int.parse(_month.substring(0, 4)), int.parse(_month.substring(5))),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    _setMonth(
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}');
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

  Future<void> _paymentDialog() {
    final amount = TextEditingController();
    final note = TextEditingController();
    int? cardId = _cards.isNotEmpty ? _cards[0]['id'] as int : null;
    var paidOn = DateTime.now();
    String? amountError;
    final screenContext = context;

    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: const Text('Log payment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: cardId,
                decoration: const InputDecoration(labelText: 'Card'),
                items: [
                  for (final c in _cards)
                    DropdownMenuItem(
                        value: c['id'] as int, child: Text(c['name'] as String)),
                ],
                onChanged: (v) => setDialog(() => cardId = v),
              ),
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: r'$',
                    errorText: amountError),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Paid on'),
                subtitle: Text(_isoDate(paidOn)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: dialogContext,
                    initialDate: paidOn,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now().add(const Duration(days: 366)),
                  );
                  if (picked != null) setDialog(() => paidOn = picked);
                },
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (cardId == null) return;
                final cents = parseCents(amount.text);
                if (cents == null || cents <= 0) {
                  setDialog(() => amountError = 'Enter an amount, like 125.00');
                  return;
                }
                final body = <String, dynamic>{
                  'card_id': cardId,
                  'amount_cents': cents,
                  'paid_on': _isoDate(paidOn),
                  'month': _month,
                  if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
                };
                final api = ApiScope.of(screenContext);
                Navigator.pop(dialogContext);
                _mutate('Payment logged', () => api.post('/api/payments', body));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  String _cardName(int cardId) {
    for (final c in _cards) {
      if (c['id'] == cardId) return c['name'] as String;
    }
    return 'Card #$cardId';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: InkWell(
            key: const Key('month-picker'),
            onTap: _pickMonth,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(monthLabel(_month)),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Previous month',
              key: const Key('prev-month'),
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _shiftMonth(-1),
            ),
            IconButton(
              tooltip: 'Next month',
              key: const Key('next-month'),
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _shiftMonth(1),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: 'Log payment',
          key: const Key('add-payment'),
          onPressed: _paymentDialog,
          child: const Icon(Icons.add),
        ),
        body: FutureBuilder<List<dynamic>>(
          future: _future,
          builder: (context, snap) => AsyncView<List<dynamic>>(
            snapshot: snap,
            onRetry: _refresh,
            builder: (payments) => _list(payments),
          ),
        ),
      );

  Widget _list(List<dynamic> payments) {
    if (payments.isEmpty) {
      return const Center(child: Text('No payments this month'));
    }
    final byCard = <int, List<Map<String, dynamic>>>{};
    for (final p in payments) {
      byCard.putIfAbsent(p['card_id'] as int, () => []).add(p as Map<String, dynamic>);
    }
    final cardIds = byCard.keys.toList()..sort();
    return Refresher(
      onRefresh: () async => _refresh(),
      child: ListView(
        children: [
          for (final cardId in cardIds) ...[
            Padding(
              key: Key('card-group-$cardId'),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(_cardName(cardId),
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final p in byCard[cardId]!)
              ListTile(
                key: Key('payment-${p['id']}-$cardId'),
                title: Text(money(p['amount_cents'] as int)),
                subtitle: Text([
                  if (p['paid_on'] != null) shortDate(p['paid_on'] as String),
                  if (p['note'] != null) p['note'] as String,
                ].join(' · ')),
                trailing: IconButton(
                  tooltip: 'Delete payment',
                  key: Key('delete-payment-${p['id']}'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _mutate('Deleted',
                      () => ApiScope.of(context).delete('/api/payments/${p['id']}')),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
