// Small display helpers shared by the transcript. Ported from
// web/src/lib/format.ts (the pure string/number helpers; session-title
// helpers stay web-side because they read web API types).

import 'dart:math' as math;

/// `proj` from `/a/b/proj/`, `''` from `''`/null.
String basename(String? path) {
  if (path == null || path.isEmpty) return '';
  final trimmed = path.replaceAll(RegExp(r'/+$'), '');
  final i = trimmed.lastIndexOf('/');
  if (i < 0) return trimmed;
  final base = trimmed.substring(i + 1);
  return base.isEmpty ? '/' : base;
}

/// "now", "5m", "3h", "3d" style stamps kept short for the rail.
String relativeTime(int ms, int now) {
  final s = math.max(0, ((now - ms) / 1000).round());
  if (s < 45) return 'now';
  final m = (s / 60).round();
  if (m < 60) return '${m}m';
  final h = (m / 60).round();
  if (h < 24) return '${h}h';
  final d = (h / 24).round();
  if (d < 14) return '${d}d';
  return shortDate(ms);
}

/// Locale-independent stand-in for the web's toLocaleDateString short date
/// (tests pin the format; the widgets pass precomputed strings anyway).
String shortDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toUtc();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}';
}

/// "0.4 s", "12 s", "3 m 5 s" as shown under tool rows and thinking rows.
String duration(num? ms) {
  if (ms == null || ms.isNaN || ms < 0) return '';
  if (ms < 1000) return '${(ms.round() < 1 ? 1 : ms.round())} ms';
  final s = ms / 1000;
  if (s < 10) return '${s.toStringAsFixed(1)} s';
  if (s < 60) return '${s.round()} s';
  final m = s ~/ 60;
  final rest = (s % 60).round();
  return rest != 0 ? '$m m $rest s' : '$m m';
}

/// "12", "1.2k", "3.4M" for token counts.
String compactNumber(num n) {
  if (n.isNaN || n.isInfinite) return '';
  if (n < 1000) return n.round().toString();
  if (n < 1000000) {
    final v = (n / 1000).toStringAsFixed(n < 10000 ? 1 : 0);
    return '${v.replaceFirst(RegExp(r'\.0$'), '')}k';
  }
  final v = (n / 1000000).toStringAsFixed(1);
  return '${v.replaceFirst(RegExp(r'\.0$'), '')}M';
}

/// "$0.01", "$12.50", "<$0.01" for cost.
String money(num usd) {
  if (usd.isNaN || usd.isInfinite || usd <= 0) return '\$0.00';
  if (usd < 0.01) return '<\$0.01';
  return '\$${usd.toStringAsFixed(2)}';
}

/// Price per million tokens as shown in the model picker: "$3 / $15", or "free".
String priceLabel(double? input, double? output) {
  if (input == null || output == null || (input == 0 && output == 0)) {
    return 'free';
  }
  String f(double n) {
    if (n < 1) {
      var s = n.toStringAsFixed(2);
      if (s.endsWith('0')) s = s.substring(0, s.length - 1);
      return s;
    }
    final v = double.parse(n.toStringAsFixed(2));
    return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  }

  return '\$${f(input)} / \$${f(output)}';
}

typedef ContextLevel = String; // 'ok' | 'warn' | 'err'

/// Amber from 70 %, red from 85 %.
ContextLevel contextLevel(num? percent) {
  if (percent == null || percent.isNaN || percent.isInfinite) return 'ok';
  if (percent >= 85) return 'err';
  if (percent >= 70) return 'warn';
  return 'ok';
}

class TextPart {
  final String text;
  final bool code;
  const TextPart(this.text, {required this.code});

  @override
  bool operator ==(Object other) =>
      other is TextPart && other.text == text && other.code == code;

  @override
  int get hashCode => Object.hash(text, code);

  @override
  String toString() => 'TextPart($text, code: $code)';
}

final RegExp _inlineCode = RegExp(r'`([^`\n]+)`');

/// Splits [text] on paired backticks so callers can style code spans without
/// touching markup.
List<TextPart> splitInlineCode(String text) {
  final parts = <TextPart>[];
  var last = 0;
  for (final m in _inlineCode.allMatches(text)) {
    if (m.start > last) parts.add(TextPart(text.substring(last, m.start), code: false));
    parts.add(TextPart(m.group(1)!, code: true));
    last = m.end;
  }
  if (last < text.length) parts.add(TextPart(text.substring(last), code: false));
  return parts;
}

String firstLine(String? text) {
  final t = text ?? '';
  final nl = t.indexOf('\n');
  return (nl < 0 ? t : t.substring(0, nl)).trim();
}

/// "12m", "3h 5m", "2d 4h" for how long something has been up.
String uptime(num? sec) {
  if (sec == null || sec.isNaN || sec < 0) return '';
  final s = sec.toDouble();
  final m = s ~/ 60;
  if (m < 1) return '${s ~/ 1}s';
  if (m < 60) return '${m}m';
  final h = m ~/ 60;
  if (h < 24) return m % 60 != 0 ? '${h}h ${m % 60}m' : '${h}h';
  final d = h ~/ 24;
  return h % 24 != 0 ? '${d}d ${h % 24}h' : '${d}d';
}
