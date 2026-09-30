// Usage ledger model, ported from web UsageView.svelte's LedgerResponse /
// LedgerSessionsResponse handling. Pure Dart: parses the /api/ledger and
// /api/ledger/sessions JSON robustly, so missing or odd fields become 0 /
// empty instead of crashing (the wire contract is in the gateway's
// docs/API.md, 'Usage ledger').

/// `totals` object: `{turns, turnsOk, input, output, cacheRead, cacheWrite,
/// cost}`.
class LedgerTotals {
  const LedgerTotals({
    this.turns = 0,
    this.turnsOk = 0,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.cost = 0,
  });

  final int turns;
  final int turnsOk;
  final double input;
  final double output;
  final double cacheRead;
  final double cacheWrite;
  final double cost;

  factory LedgerTotals.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return LedgerTotals(
      turns: intFrom(m['turns']),
      turnsOk: intFrom(m['turnsOk']),
      input: numFrom(m['input']),
      output: numFrom(m['output']),
      cacheRead: numFrom(m['cacheRead']),
      cacheWrite: numFrom(m['cacheWrite']),
      cost: numFrom(m['cost']),
    );
  }
}

/// One zero-filled day bucket from `perDay`: `{date, input, output, cost}`.
/// `date` is the gateway's own ISO calendar day; use it as-is (DST safe).
class LedgerDay {
  const LedgerDay({
    this.date = '',
    this.input = 0,
    this.output = 0,
    this.cost = 0,
  });

  final String date;
  final double input;
  final double output;
  final double cost;

  factory LedgerDay.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return LedgerDay(
      date: m['date'] is String ? m['date'] as String : '',
      input: numFrom(m['input']),
      output: numFrom(m['output']),
      cost: numFrom(m['cost']),
    );
  }
}

/// One `perModel` row: `{provider, model, turns, input, output, cacheRead,
/// cost}`.
class LedgerModelRow {
  const LedgerModelRow({
    this.provider = '',
    this.model = '',
    this.turns = 0,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cost = 0,
  });

  final String provider;
  final String model;
  final int turns;
  final double input;
  final double output;
  final double cacheRead;
  final double cost;

  factory LedgerModelRow.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return LedgerModelRow(
      provider: m['provider'] is String ? m['provider'] as String : '',
      model: m['model'] is String ? m['model'] as String : '',
      turns: intFrom(m['turns']),
      input: numFrom(m['input']),
      output: numFrom(m['output']),
      cacheRead: numFrom(m['cacheRead']),
      cost: numFrom(m['cost']),
    );
  }

  /// Stable identity for the filter and list keys, matching the web's
  /// `m.model + '/' + m.provider`.
  String get key => '$model/$provider';
}

/// One `sessions` row: `{sessionName, cwd, turns, input, output, cacheRead,
/// cost, lastTs}` with `lastTs` in epoch seconds.
class LedgerSession {
  const LedgerSession({
    this.sessionName = '',
    this.cwd = '',
    this.turns = 0,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cost = 0,
    this.lastTs = 0,
  });

  final String sessionName;
  final String cwd;
  final int turns;
  final double input;
  final double output;
  final double cacheRead;
  final double cost;
  final int lastTs;

  factory LedgerSession.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return LedgerSession(
      sessionName: m['sessionName'] is String ? m['sessionName'] as String : '',
      cwd: m['cwd'] is String ? m['cwd'] as String : '',
      turns: intFrom(m['turns']),
      input: numFrom(m['input']),
      output: numFrom(m['output']),
      cacheRead: numFrom(m['cacheRead']),
      cost: numFrom(m['cost']),
      lastTs: intFrom(m['lastTs']),
    );
  }

  /// sessionLabel from UsageView: trimmed name, else cwd basename, else
  /// 'Unnamed'.
  String label() {
    final name = sessionName.trim();
    if (name.isNotEmpty) return name;
    final base = basenameOf(cwd);
    return base.isEmpty ? 'Unnamed' : base;
  }
}

/// The parsed /api/ledger response: `{days, totals, perDay, perModel}`.
class LedgerAgg {
  const LedgerAgg({
    this.days = 30,
    this.totals = const LedgerTotals(),
    this.perDay = const [],
    this.perModel = const [],
  });

  final int days;
  final LedgerTotals totals;
  final List<LedgerDay> perDay;
  final List<LedgerModelRow> perModel;

  factory LedgerAgg.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return LedgerAgg(
      days: intFrom(m['days'], fallback: 30),
      totals: LedgerTotals.fromJson(m['totals']),
      perDay: listOf(m['perDay'], LedgerDay.fromJson),
      perModel: listOf(m['perModel'], LedgerModelRow.fromJson),
    );
  }

  /// Highest in+out across the chart days, floor 1 so empty ranges divide
  /// safely (chartMax from UsageView).
  double get chartMax {
    var max = 1.0;
    for (final d in perDay) {
      final v = d.input + d.output;
      if (v > max) max = v;
    }
    return max;
  }
}

/// The parsed /api/ledger/sessions response: `{days, sessions}`.
class LedgerRollup {
  const LedgerRollup({this.days = 30, this.sessions = const []});

  final int days;
  final List<LedgerSession> sessions;

  factory LedgerRollup.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return LedgerRollup(
      days: intFrom(m['days'], fallback: 30),
      sessions: listOf(m['sessions'], LedgerSession.fromJson),
    );
  }
}

/// Narrowed int at the JSON boundary: null, non-num and non-finite become
/// [fallback].
int intFrom(Object? v, {int fallback = 0}) {
  if (v is! num) return fallback;
  if (v.isNaN || v.isInfinite) return fallback;
  return v.round();
}

/// Narrowed double at the JSON boundary: null, non-num and non-finite become
/// [fallback].
double numFrom(Object? v, {double fallback = 0}) {
  if (v is! num) return fallback;
  if (v.isNaN || v.isInfinite) return fallback;
  return v.toDouble();
}

/// `basename` from web/src/lib/format.ts, kept here so this module stays
/// importable from pure tests.
String basenameOf(String? path) {
  if (path == null || path.isEmpty) return '';
  final trimmed = path.replaceAll(RegExp(r'/+$'), '');
  final i = trimmed.lastIndexOf('/');
  if (i < 0) return trimmed;
  final base = trimmed.substring(i + 1);
  return base.isEmpty ? '/' : base;
}

List<T> listOf<T>(Object? v, T Function(Object?) fromJson) {
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e != null) fromJson(e),
  ];
}
