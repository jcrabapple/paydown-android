import 'package:flutter/material.dart';

import '../api/client.dart';
import '../format.dart';
import '../widgets.dart';

/// Lane F (docs/ANDROID1.md). Settings, income, pay schedules, deposit rules.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<(Map<String, dynamic>, List<dynamic>, List<dynamic>,
      List<dynamic>)> _future;

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

  Future<(Map<String, dynamic>, List<dynamic>, List<dynamic>, List<dynamic>)>
      _load() async {
    final client = ApiScope.of(context);
    final r = await Future.wait([
      client.get('/api/settings'),
      client.get('/api/income'),
      client.get('/api/pay-schedules'),
      client.get('/api/deposit-rules'),
    ]);
    return (
      (r[0] as Map? ?? const {}).cast<String, dynamic>(),
      r[1] as List? ?? const [],
      r[2] as List? ?? const [],
      r[3] as List? ?? const [],
    );
  }

  void _retry() => setState(() {
      _future = _load();
    });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: FutureBuilder<
            (Map<String, dynamic>, List<dynamic>, List<dynamic>,
                List<dynamic>)>(
          future: _future,
          builder: (context, snap) => AsyncView<
              (Map<String, dynamic>, List<dynamic>, List<dynamic>,
                  List<dynamic>)>(
            snapshot: snap,
            onRetry: _retry,
            builder: (data) => Refresher(
              onRefresh: () async {
                _retry();
                await _future;
              },
              child: _SettingsBody(
                settings: data.$1,
                income: data.$2,
                schedules: data.$3,
                rules: data.$4,
                onChanged: _retry,
              ),
            ),
          ),
        ),
      );
}

class _SettingsBody extends StatefulWidget {
  const _SettingsBody({
    required this.settings,
    required this.income,
    required this.schedules,
    required this.rules,
    required this.onChanged,
  });

  final Map<String, dynamic> settings;
  final List<dynamic> income;
  final List<dynamic> schedules;
  final List<dynamic> rules;
  final VoidCallback onChanged;

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  late String _strategy;
  late int _bufferCents;
  late int _debtSharePct;
  late int? _extraOverrideCents;
  late int _cashFloorCents;
  late int _cashReserveMonths;
  late bool _autoLog;

  @override
  void initState() {
    super.initState();
    _syncFromSettings();
  }

  @override
  void didUpdateWidget(covariant _SettingsBody old) {
    super.didUpdateWidget(old);
    if (old.settings != widget.settings) _syncFromSettings();
  }

  void _syncFromSettings() {
    final s = widget.settings;
    _strategy = (s['strategy'] ?? 'avalanche') as String;
    _bufferCents = _asInt(s['buffer_cents']);
    _debtSharePct = _asInt(s['debt_share_pct']);
    _extraOverrideCents =
        s['extra_override_cents'] == null ? null : _asInt(s['extra_override_cents']);
    _cashFloorCents = _asInt(s['cash_floor_cents']);
    _cashReserveMonths = _asInt(s['cash_reserve_months']);
    _autoLog = s['auto_log_card_payments'] == true;
  }

  // ---------------------------------------------------------------- settings

  bool get _dirty =>
      _strategy != widget.settings['strategy'] ||
      _bufferCents != _asInt(widget.settings['buffer_cents']) ||
      _debtSharePct != _asInt(widget.settings['debt_share_pct']) ||
      _extraOverrideCents != widget.settings['extra_override_cents'] ||
      _cashFloorCents != _asInt(widget.settings['cash_floor_cents']) ||
      _cashReserveMonths != _asInt(widget.settings['cash_reserve_months']) ||
      _autoLog != (widget.settings['auto_log_card_payments'] == true);

  Future<void> _save() async {
    // PUT only changed fields.
    final body = <String, dynamic>{};
    if (_strategy != widget.settings['strategy']) body['strategy'] = _strategy;
    if (_bufferCents != _asInt(widget.settings['buffer_cents'])) {
      body['buffer_cents'] = _bufferCents;
    }
    if (_debtSharePct != _asInt(widget.settings['debt_share_pct'])) {
      body['debt_share_pct'] = _debtSharePct;
    }
    if (_extraOverrideCents != widget.settings['extra_override_cents']) {
      body['extra_override_cents'] = _extraOverrideCents;
    }
    if (_cashFloorCents != _asInt(widget.settings['cash_floor_cents'])) {
      body['cash_floor_cents'] = _cashFloorCents;
    }
    if (_cashReserveMonths != _asInt(widget.settings['cash_reserve_months'])) {
      body['cash_reserve_months'] = _cashReserveMonths;
    }
    if (_autoLog != (widget.settings['auto_log_card_payments'] == true)) {
      body['auto_log_card_payments'] = _autoLog;
    }
    if (body.isEmpty) {
      toast(context, 'No changes');
      return;
    }
    try {
      await ApiScope.of(context).put('/api/settings', body);
      if (!mounted) return;
      toast(context, 'Settings saved');
      widget.onChanged();
    } on ApiError catch (e) {
      if (!mounted) return;
      showError(context, e.message);
    }
  }

  // ------------------------------------------------------------------ income

  Future<void> _incomeDialog({Map<String, dynamic>? existing}) async {
    final name = TextEditingController(text: existing?['name']?.toString());
    final amount = TextEditingController(
        text: existing == null
            ? ''
            : ((existing['amount_cents'] as num? ?? 0) / 100).toStringAsFixed(2));
    var active = existing?['active'] == null
        ? true
        : (existing!['active'] == 1 || existing['active'] == true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'Add income' : 'Edit income'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name')),
            TextField(
              controller: amount,
              decoration: const InputDecoration(
                  labelText: 'Monthly amount (\$)'), keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            ),
            StatefulBuilder(
              builder: (context, setDialog) => CheckboxListTile(
                value: active,
                onChanged: (_) => setDialog(() => active = !active),
                title: const Text('Active'),
              ),
            ),
          ],
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
    );
    if (ok != true || !mounted) return;
    final cents = parseCents(amount.text);
    if (cents == null) {
      showError(context, 'Enter a valid amount, like 1234.56.');
      return;
    }
    final body = {
      'name': name.text.trim(),
      'amount_cents': cents,
      'active': active,
    };
    try {
      final client = ApiScope.of(context);
      if (existing == null) {
        await client.post('/api/income', body);
      } else {
        await client.put('/api/income/${existing['id']}', body);
      }
      if (!mounted) return;
      toast(context, 'Income saved');
      widget.onChanged();
    } on ApiError catch (e) {
      if (!mounted) return;
      showError(context, e.message);
    }
  }

  Future<void> _deleteIncome(Map<String, dynamic> item) async {
    try {
      await ApiScope.of(context).delete('/api/income/${item['id']}');
      if (!mounted) return;
      toast(context, 'Deleted');
      widget.onChanged();
    } on ApiError catch (e) {
      if (!mounted) return;
      showError(context, e.message);
    }
  }

  // ----------------------------------------------------------- pay schedules

  static const _frequencies = ['weekly', 'biweekly', 'semimonthly', 'monthly'];

  Future<void> _scheduleDialog({Map<String, dynamic>? existing}) async {
    final name = TextEditingController(text: existing?['name']?.toString());
    final anchor =
        TextEditingController(text: existing?['anchor_date']?.toString() ?? '');
    final amount = TextEditingController(
        text: existing == null
            ? ''
            : ((existing['amount_cents'] as num? ?? 0) / 100).toStringAsFixed(2));
    var frequency = (existing?['frequency'] ?? 'weekly') as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(existing == null ? 'Add pay schedule' : 'Edit pay schedule'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name')),
              DropdownButtonFormField<String>(
                initialValue: frequency,
                items: [
                  for (final f in _frequencies)
                    DropdownMenuItem(value: f, child: Text(f)),
                ],
                onChanged: (v) => setDialog(() => frequency = v ?? frequency),
                decoration: const InputDecoration(labelText: 'Frequency'),
              ),
              TextField(
                controller: anchor,
                decoration:
                    const InputDecoration(labelText: 'Anchor date (YYYY-MM-DD)'),
              ),
              TextField(
                controller: amount,
                decoration: const InputDecoration(
                    labelText: 'Amount (\$)'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
            ],
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
    if (ok != true || !mounted) return;
    final cents = amount.text.trim().isEmpty ? null : parseCents(amount.text);
    if (amount.text.trim().isNotEmpty && cents == null) {
      showError(context, 'Enter a valid amount, like 1234.56.');
      return;
    }
    final body = <String, dynamic>{
      'name': name.text.trim(),
      'frequency': frequency,
      'anchor_date': anchor.text.trim(),
      'amount_cents': ?cents,
    };
    try {
      final client = ApiScope.of(context);
      if (existing == null) {
        await client.post('/api/pay-schedules', body);
      } else {
        await client.put('/api/pay-schedules/${existing['id']}', body);
      }
      if (!mounted) return;
      toast(context, 'Pay schedule saved');
      widget.onChanged();
    } on ApiError catch (e) {
      if (!mounted) return;
      showError(context, e.message);
    }
  }

  Future<void> _deleteSchedule(Map<String, dynamic> s) async {
    try {
      await ApiScope.of(context).delete('/api/pay-schedules/${s['id']}');
      if (!mounted) return;
      toast(context, 'Deleted');
      widget.onChanged();
    } on ApiError catch (e) {
      if (!mounted) return;
      showError(context, e.message);
    }
  }

  Future<void> _detect() async {
    try {
      final r =
          await ApiScope.of(context).post('/api/pay-schedules/detect', {});
      if (!mounted) return;
      final s = (r is Map ? r['suggestion'] : null) as Map?;
      if (s == null) {
        toast(context, (r is Map ? r['reason'] : null)?.toString() ?? 'No suggestion');
      } else {
        toast(context, 'Detected: ${s['name'] ?? s['frequency'] ?? 'schedule'}');
      }
      widget.onChanged();
    } on ApiError catch (e) {
      if (!mounted) return;
      showError(context, e.message);
    }
  }

  Future<void> _useAsIncome(Map<String, dynamic> s) async {
    try {
      await ApiScope.of(context)
          .post('/api/pay-schedules/${s['id']}/use-as-income', {});
      if (!mounted) return;
      toast(context, 'Linked to income');
      widget.onChanged();
    } on ApiError catch (e) {
      if (!mounted) return;
      showError(context, e.message);
    }
  }

  // ----------------------------------------------------------- deposit rules

  Future<void> _previewRule(Map<String, dynamic> rule) async {
    final controller = TextEditingController(text: rule['match_text']?.toString());
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Preview "${rule['label'] ?? rule['match_text']}"'),
        content: StatefulBuilder(
          builder: (context, setDialog) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration:
                    const InputDecoration(labelText: 'Match text'),
                onSubmitted: (_) async {
                  setDialog(() {});
                },
              ),
              const SizedBox(height: 8),
              FutureBuilder<Map<String, dynamic>>(
                future: _runPreview(controller.text),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Text(
                      (snap.error is ApiError)
                          ? (snap.error as ApiError).message
                          : '${snap.error}',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    );
                  }
                  if (!snap.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(),
                    );
                  }
                  final samples = (snap.data!['samples'] as List? ?? const []);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${snap.data!['count']} matching deposits'),
                      for (final s in samples.take(5))
                        Text(
                          '${shortDate((s as Map)['date'] as String)} '
                          '${money(_asInt(s['amount_cents']))} ${s['name']}',
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> _runPreview(String text) async {
    final r = await ApiScope.of(context)
        .get('/api/deposit-rules/preview?text=${Uri.encodeComponent(text)}');
    return (r as Map? ?? const {}).cast<String, dynamic>();
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Strategy', style: theme.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'avalanche', label: Text('Avalanche')),
              ButtonSegment(value: 'snowball', label: Text('Snowball')),
              ButtonSegment(value: 'custom', label: Text('Custom')),
            ],
            selected: {_strategy},
            onSelectionChanged: (s) => setState(() => _strategy = s.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              _numTile('Buffer (\$)', money(_bufferCents),
                  (v) => setState(() => _bufferCents = _editedCents(v, _bufferCents))),
              _numTile('Debt share %', '$_debtSharePct%',
                  (v) => setState(
                      () => _debtSharePct = _editedInt(v, _debtSharePct, 0, 100))),
              _numTile('Extra override (\$)',
                  _extraOverrideCents == null ? '' : money(_extraOverrideCents!),
                  (v) => setState(() => _extraOverrideCents = v.trim().isEmpty
                      ? null
                      : _editedCents(v, _extraOverrideCents ?? 0))),
              _numTile('Cash floor (\$)', money(_cashFloorCents),
                  (v) => setState(() => _cashFloorCents = _editedCents(v, _cashFloorCents))),
              _numTile('Cash reserve months', '$_cashReserveMonths',
                  (v) => setState(() => _cashReserveMonths =
                      _editedInt(v, _cashReserveMonths, 0, 6))),
              SwitchListTile(
                title: const Text('Auto-log card payments'),
                value: _autoLog,
                onChanged: (v) => setState(() => _autoLog = v),
              ),
              FilledButton(
                onPressed: _dirty ? _save : null,
                child: const Text('Save settings'),
              ),
            ],
          ),
        ),
        const Divider(height: 32),
        _sectionHeader('Income', onTapAdd: () => _incomeDialog()),
        for (final i in widget.income)
          InfoRow(
            title: i['name']?.toString() ?? '',
            subtitle: (i['active'] == 1 || i['active'] == true)
                ? null
                : 'inactive',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(money(_asInt(i['amount_cents']))),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit',
                onPressed: () => _incomeDialog(existing: i as Map<String, dynamic>),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: () => _deleteIncome(i as Map<String, dynamic>),
              ),
            ]),
          ),
        const Divider(height: 32),
        _sectionHeader(
          'Pay schedules',
          onTapAdd: () => _scheduleDialog(),
          extra: TextButton.icon(
            onPressed: _detect,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('Detect'),
          ),
        ),
        for (final raw in widget.schedules)
          Builder(builder: (context) {
            final s = (raw as Map).cast<String, dynamic>();
            return InfoRow(
              title: (s['name'] ?? '') as String,
              subtitle:
                  '${s['frequency'] ?? ''} · ${money(_asInt(s['monthly_equivalent_cents']))}/mo',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(
                  onPressed: () => _useAsIncome(s),
                  child: const Text('Use as income'),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit',
                  onPressed: () => _scheduleDialog(existing: s),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () => _deleteSchedule(s),
                ),
              ]),
            );
          }),
        const Divider(height: 32),
        _sectionHeader('Deposit rules'),
        if (widget.rules.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('No deposit rules yet.'),
          ),
        for (final raw in widget.rules)
          Builder(builder: (context) {
            final r = (raw as Map).cast<String, dynamic>();
            return InfoRow(
              title: (r['label'] ?? r['match_text'] ?? '') as String,
              subtitle: r['pay_schedule_name'] == null
                  ? '${r['labelled_count'] ?? 0} deposits labelled'
                  : '${r['pay_schedule_name']} · ${r['labelled_count'] ?? 0} deposits labelled',
              trailing: TextButton(
                onPressed: () => _previewRule(r),
                child: const Text('Preview'),
              ),
            );
          }),
      ],
    );
  }

  Widget _sectionHeader(String title,
      {VoidCallback? onTapAdd, Widget? extra}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          if (extra != null)
            extra
          else if (onTapAdd != null)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Add',
              onPressed: onTapAdd,
            ),
        ],
      ),
    );
  }

  Widget _numTile(
          String label, String display, ValueChanged<String> onSaved) =>
      _NumTile(label: label, display: display, onSaved: onSaved);
}

class _NumTile extends StatefulWidget {
  const _NumTile(
      {required this.label, required this.display, required this.onSaved});

  final String label;
  final String display;
  final ValueChanged<String> onSaved;

  @override
  State<_NumTile> createState() => _NumTileState();
}

class _NumTileState extends State<_NumTile> {
  late final TextEditingController _controller =
      TextEditingController(text: _dollarsText(widget.display));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(widget.label),
        subtitle: Text(widget.display),
        trailing: const Icon(Icons.edit_outlined, size: 18),
        onTap: () async {
          // Re-seed from the CURRENT value each time: settings reload after a
          // save, and a cancelled edit must not leak into the next open.
          _controller.text = _dollarsText(widget.display);
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(widget.label),
              content: TextField(
                controller: _controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onSubmitted: (v) => Navigator.pop(context, true),
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
          );
          if (ok == true) widget.onSaved(_controller.text);
        },
      );
}

/// Dialog-committed money field: blank -> 0; anything unparseable keeps
/// [current], so a typo like "1.2.3" never silently saves as \$0.
int _editedCents(String text, int current) =>
    text.trim().isEmpty ? 0 : (parseCents(text) ?? current);

/// Dialog-committed integer in [min, max]; out-of-range or junk keeps
/// [current] (the server would 422 it anyway).
int _editedInt(String text, int current, int min, int max) {
  final v = int.tryParse(text.trim().replaceAll('%', ''));
  return (v == null || v < min || v > max) ? current : v;
}

/// Strips non-numeric characters from a display value for re-editing.
String _dollarsText(String display) =>
    display.replaceAll(RegExp(r'[^\d.]'), '');

int _asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
