import 'package:intl/intl.dart';

final _usd = NumberFormat.currency(symbol: r'$');

/// 123456 -> "$1,234.56". Negative cents render as -$1,234.56.
String money(int cents) => _usd.format(cents / 100.0);

/// 2499 -> "24.99%" (card APRs are percent values, not cents).
String pct(num value) => '${value.toStringAsFixed(2)}%';

/// "2026-10" -> "October 2026".
String monthLabel(String ym) {
  final (y, m) = (int.parse(ym.substring(0, 4)), int.parse(ym.substring(5)));
  return DateFormat.yMMMM().format(DateTime(y, m));
}

/// "2026-10-27" -> "Oct 27".
String shortDate(String iso) =>
    DateFormat.MMMd().format(DateTime.parse(iso));

// Up to 12 whole-dollar digits: past the server's MAX_CENTS cap, and short
// enough that int.parse can never overflow on pasted junk.
final _centsRe = RegExp(r'^(\d{1,12})(?:\.(\d{0,2}))?$');

/// User-typed dollars -> exact cents, or null when blank or not a valid
/// non-negative amount. Accepts "$1,234.56", "1234.5", "1234", ".99";
/// rejects "1.234", "abc", "-5", "1.2.3". String math, never double, so
/// "0.29" is 29 exactly.
int? parseCents(String input) {
  final t = input.replaceAll(RegExp(r'[\s$,]'), '');
  if (t.isEmpty) return null;
  final m = _centsRe.firstMatch(t.startsWith('.') ? '0$t' : t);
  if (m == null) return null;
  final whole = int.parse(m.group(1)!);
  final frac = (m.group(2) ?? '').padRight(2, '0');
  return whole * 100 + int.parse(frac);
}

/// Cents -> plain editable text ("123456" -> "1234.56").
String centsText(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
