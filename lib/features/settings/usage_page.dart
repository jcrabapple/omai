// Usage settings page. The History section ports web UsageView.svelte: the
// /api/ledger aggregates (day-range picker, totals, stacked daily token
// chart, per-model table) plus the /api/ledger/sessions per-session rollup,
// with a model filter, a refetch-error banner that keeps the last good
// data, and a "newer gateway" note when /ledger is a 404. Below it, the
// /api/usage report is rendered from ANSI escapes through
// lib/render/ansi.dart, in monospace inside a horizontally scrollable,
// selectable region. A Refresh button re-fetches both (the gateway can take
// up to about 90 seconds). The response's own error text is shown when
// present; an empty report gets a note.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../format.dart';
import '../../render/ansi.dart';
import '../../state/connection_notifier.dart';
import '../../theme/tokens.dart';
import 'settings_widgets.dart';
import 'usage_ledger.dart';
import 'usage_ledger_chart.dart';

const _ledgerRanges = [7, 30, 90];

/// Parsed /api/usage response: {raw, error?}.
class UsageReport {
  const UsageReport({this.raw = '', this.error});
  final String raw;
  final String? error;

  factory UsageReport.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return UsageReport(
      raw: m['raw'] is String ? m['raw'] as String : '',
      error: m['error'] is String ? m['error'] as String : null,
    );
  }
}

class UsagePage extends ConsumerStatefulWidget {
  const UsagePage({super.key});

  @override
  ConsumerState<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends ConsumerState<UsagePage> {
  UsageReport? _report;
  String? _error;
  bool _loading = true;

  // History (ledger) state.
  int _ledgerDays = 30;
  LedgerAgg? _agg;
  LedgerRollup? _roll;
  String? _ledgerError;
  String? _ledgerRefetchError;
  bool _ledgerUnsupported = false;
  bool _ledgerLoading = true;
  String? _filterKey; // 'model/provider' from perModel, null = all.

  /// Bumps on every load: a response from a previous load or connection
  /// must never overwrite a newer one (review triage #13). Two counters so
  /// the slow /api/usage fetch cannot clobber a fast ledger refetch.
  int _loadGen = 0;
  int _ledgerGen = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadLedger();
    // The connection notifier may still be settling when the page opens;
    // reload once the active connection appears.
    ref.listenManual(connectionNotifierProvider, (prev, next) {
      final idle = _report == null && _error == null && !_loading;
      final ledgerIdle =
          _agg == null && _ledgerError == null && !_ledgerLoading;
      if (prev?.active == null && next.active != null) {
        if (idle) _load();
        if (ledgerIdle) _loadLedger();
      }
    });
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
    });
    final active = ref.read(connectionNotifierProvider).active;
    if (active == null || !mounted || gen != _loadGen) {
      if (mounted && gen == _loadGen) {
        setState(() => _loading = false);
      }
      return;
    }
    final token = await ref.read(tokenStoreProvider).read(active.id);
    if (!mounted || gen != _loadGen) return;
    final client = ref.read(gatewayClientFactoryProvider)(
      active.url,
      token ?? '',
    );
    try {
      final json = await client.usage();
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _report = UsageReport.fromJson(json);
        _loading = false;
      });
    } on GatewayClientError catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = 'Could not reach the gateway.';
        _loading = false;
      });
    }
  }

  /// Loads the ledger aggregates and the per-session rollup for the current
  /// range. Stale beats loading: the previous numbers stay on screen until
  /// the refetch answers, and a response from an older request is dropped.
  Future<void> _loadLedger() async {
    final gen = ++_ledgerGen;
    final days = _ledgerDays;
    final filter = _filterKey;
    final parts = filter?.split('/');
    final model = (parts == null || parts.first.isEmpty) ? null : parts.first;
    final provider = (parts == null || parts.length < 2 || parts[1].isEmpty)
        ? null
        : parts[1];
    setState(() {
      _ledgerLoading = true;
      _ledgerRefetchError = null;
    });
    if (!mounted || gen != _ledgerGen) return;
    final active = ref.read(connectionNotifierProvider).active;
    if (active == null) {
      setState(() => _ledgerLoading = false);
      return;
    }
    final token = await ref.read(tokenStoreProvider).read(active.id);
    if (!mounted || gen != _ledgerGen) return;
    final client = ref.read(gatewayClientFactoryProvider)(
      active.url,
      token ?? '',
    );
    try {
      final results = await Future.wait([
        client.ledger(days: days, model: model, provider: provider),
        client.ledgerSessions(days: days),
      ]);
      if (!mounted || gen != _ledgerGen) return;
      setState(() {
        _agg = LedgerAgg.fromJson(results[0]);
        _roll = LedgerRollup.fromJson(results[1]);
        _ledgerUnsupported = false;
        _ledgerError = null;
        _ledgerRefetchError = null;
        _ledgerLoading = false;
      });
    } on GatewayError catch (e) {
      if (!mounted || gen != _ledgerGen) return;
      if (e.status == 404) {
        setState(() {
          _ledgerUnsupported = true;
          _ledgerError = null;
          _ledgerRefetchError = null;
          _ledgerLoading = false;
        });
        return;
      }
      _ledgerFailure(gen, e.message);
    } on GatewayClientError catch (e) {
      _ledgerFailure(gen, e.message);
    } catch (_) {
      _ledgerFailure(gen, 'Could not reach the gateway.');
    }
  }

  void _ledgerFailure(int gen, String message) {
    if (!mounted || gen != _ledgerGen) return;
    setState(() {
      // Keep the last good data under a banner; only a first load clears it.
      if (_agg == null) {
        _ledgerError = message;
      } else {
        _ledgerRefetchError = message;
      }
      _ledgerLoading = false;
    });
  }

  void _setDays(int days) {
    if (days == _ledgerDays) return;
    setState(() => _ledgerDays = days);
    _loadLedger();
  }

  void _setFilter(String? key) {
    if (key == _filterKey) return;
    setState(() => _filterKey = key);
    _loadLedger();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final report = _report;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Usage'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        actions: [
          TextButton(
            key: const ValueKey('usage-refresh'),
            onPressed: (_loading || _ledgerLoading)
                ? null
                : () {
                    _load();
                    _loadLedger();
                  },
            child: Text(
              'Refresh',
              style: TextStyle(
                color: (_loading || _ledgerLoading)
                    ? tokens.ink3
                    : tokens.accent,
              ),
            ),
          ),
        ],
      ),
      body: SettingsPageBody(
        children: [
          _buildHistory(tokens),
          SettingsSection(
            title: 'Usage report',
            hint: 'What each provider reports for your accounts. Fetching it can take a few seconds.',
            child: SettingsLoadState(
              ready: !_loading && _error == null,
              error: _error,
              onRetry: _load,
              child: () {
                if (report == null) {
                  return Text(
                    'The gateway returned no usage data.',
                    style: TextStyle(
                      color: tokens.ink3,
                      fontSize: OmpMetrics.fsSm,
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (report.error != null)
                      Padding(
                        key: const ValueKey('usage-error-note'),
                        padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
                        child: Text(
                          report.error!,
                          style: TextStyle(
                            color: tokens.warn,
                            fontSize: OmpMetrics.fsSm,
                          ),
                        ),
                      ),
                    if (report.raw.isEmpty && report.error == null)
                      Text(
                        'The gateway returned no usage data.',
                        style: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsSm,
                        ),
                      )
                    else if (report.raw.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(OmpMetrics.s3),
                        decoration: BoxDecoration(
                          color: tokens.inset,
                          borderRadius: BorderRadius.circular(
                            OmpMetrics.radiusMd,
                          ),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SelectionArea(
                            child: Text.rich(
                              TextSpan(
                                children: ansiToSpans(
                                  report.raw,
                                  base: TextStyle(
                                    color: tokens.ink,
                                    fontSize: OmpMetrics.fsSm,
                                    fontFamily: 'monospace',
                                    height: 1.5,
                                  ),
                                ),
                              ),
                              key: const ValueKey('usage-report-text'),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              }(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistory(OmpTokens tokens) {
    if (_ledgerUnsupported) {
      return SettingsSection(
        title: 'History',
        child: Text(
          'Usage history needs a newer gateway.',
          key: const ValueKey('ledger-unsupported'),
          style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
        ),
      );
    }
    return SettingsSection(
      title: 'History',
      hint: 'Token and cost totals from the session ledger.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RangePicker(
            key: const ValueKey('ledger-range'),
            value: _ledgerDays,
            onChanged: _setDays,
          ),
          if (_ledgerRefetchError != null)
            Container(
              key: const ValueKey('ledger-refetch-banner'),
              width: double.infinity,
              margin: const EdgeInsets.only(top: OmpMetrics.s3),
              padding: const EdgeInsets.all(OmpMetrics.s2),
              decoration: BoxDecoration(
                color: tokens.warnSoft,
                borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Could not refresh usage. Showing results from the previous fetch.',
                    style: TextStyle(
                      color: tokens.warn,
                      fontSize: OmpMetrics.fsSm,
                    ),
                  ),
                  Text(
                    _ledgerRefetchError!,
                    style: TextStyle(
                      color: tokens.ink3,
                      fontSize: OmpMetrics.fsXs,
                    ),
                  ),
                ],
              ),
            ),
          if (_ledgerError != null)
            Padding(
              key: const ValueKey('ledger-error'),
              padding: const EdgeInsets.only(top: OmpMetrics.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _ledgerError!,
                    style: TextStyle(
                      color: tokens.warn,
                      fontSize: OmpMetrics.fsSm,
                    ),
                  ),
                  TextButton(
                    onPressed: _loadLedger,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          else ...[
            if (_ledgerLoading && _agg == null)
              const Padding(
                padding: EdgeInsets.only(top: OmpMetrics.s3),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              _buildLedgerBody(tokens),
          ],
        ],
      ),
    );
  }

  Widget _buildLedgerBody(OmpTokens tokens) {
    final agg = _agg;
    if (agg == null) return const SizedBox.shrink();
    final roll = _roll;
    final totals = agg.totals;
    final empty = totals.turns == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: OmpMetrics.s2),
          child: Semantics(
            label: 'Cost over the last ${agg.days} days: ${money(totals.cost)}',
            child: Text(
              '${totals.turns} ${totals.turns == 1 ? 'turn' : 'turns'} in the last ${agg.days} days',
              key: const ValueKey('ledger-subtitle'),
              style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: OmpMetrics.s2),
          child: Row(
            children: [
              _TotalCard(
                label: 'Tokens in',
                value: compactNumber(totals.input),
              ),
              _TotalCard(
                label: 'Tokens out',
                value: compactNumber(totals.output),
              ),
              _TotalCard(
                label: 'Cache read',
                value: compactNumber(totals.cacheRead),
              ),
              _TotalCard(label: 'Cost', value: money(totals.cost)),
            ],
          ),
        ),
        if (agg.perModel.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: OmpMetrics.s2),
            child: PopupMenuButton<String>(
              key: const ValueKey('ledger-filter'),
              tooltip: 'Filter by model',
              onSelected: _setFilter,
              itemBuilder: (context) => [
                const PopupMenuItem(value: '', child: Text('All models')),
                for (final m in agg.perModel)
                  PopupMenuItem(value: m.key, child: Text(m.key)),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: OmpMetrics.s2,
                  vertical: OmpMetrics.s1,
                ),
                decoration: BoxDecoration(
                  color: tokens.inset,
                  borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
                ),
                child: Text(
                  _filterKey ?? 'All models',
                  style: TextStyle(
                    color: tokens.ink2,
                    fontSize: OmpMetrics.fsSm,
                  ),
                ),
              ),
            ),
          ),
        if (empty)
          Padding(
            key: const ValueKey('ledger-empty'),
            padding: const EdgeInsets.only(top: OmpMetrics.s3),
            child: Text(
              'No turns recorded in this range.',
              style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(top: OmpMetrics.s3),
            child: Semantics(
              label:
                  'Cost over the last ${agg.days} days: ${money(totals.cost)}',
              child: LedgerBarChart(days: agg.perDay),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: OmpMetrics.s1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _shortDate(agg.perDay.isEmpty ? '' : agg.perDay.first.date),
                  style: TextStyle(
                    color: tokens.ink3,
                    fontSize: OmpMetrics.fsXs,
                  ),
                ),
                Text(
                  _shortDate(agg.perDay.isEmpty ? '' : agg.perDay.last.date),
                  style: TextStyle(
                    color: tokens.ink3,
                    fontSize: OmpMetrics.fsXs,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: OmpMetrics.s1),
            child: Row(
              children: [
                _LegendDot(color: tokens.accent, label: 'in'),
                const SizedBox(width: OmpMetrics.s2),
                _LegendDot(color: tokens.ink3, label: 'out'),
              ],
            ),
          ),
        ],
        if (agg.perModel.isNotEmpty) ...[
          _tableHeader(tokens, const [
            'Model',
            'Turns',
            'In',
            'Out',
            'Cache',
            'Cost',
          ]),
          for (final m in agg.perModel)
            _ledgerRow(
              tokens,
              key: ValueKey('ledger-model-${m.key}'),
              prime: m.model.isEmpty ? 'unknown' : m.model,
              sub: m.provider,
              cells: [
                '${m.turns}',
                compactNumber(m.input),
                compactNumber(m.output),
                compactNumber(m.cacheRead),
                money(m.cost),
              ],
            ),
        ],
        if (roll != null && roll.sessions.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: OmpMetrics.s3),
            child: Text(
              'By session',
              style: TextStyle(
                color: tokens.ink,
                fontSize: OmpMetrics.fsSm,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _tableHeader(tokens, const [
            'Session',
            'Turns',
            'In',
            'Out',
            'Cost',
            'Last',
          ]),
          for (var i = 0; i < roll.sessions.length; i++)
            _ledgerRow(
              tokens,
              key: ValueKey('ledger-session-$i'),
              prime: roll.sessions[i].label(),
              sub: roll.sessions[i].cwd.isEmpty
                  ? null
                  : basenameOf(roll.sessions[i].cwd),
              cells: [
                '${roll.sessions[i].turns}',
                compactNumber(roll.sessions[i].input),
                compactNumber(roll.sessions[i].output),
                money(roll.sessions[i].cost),
                relativeTime(
                  roll.sessions[i].lastTs * 1000,
                  DateTime.now().millisecondsSinceEpoch,
                ),
              ],
            ),
        ],
      ],
    );
  }

  static const _cellFlexes = [3, 2, 2, 2, 3, 2];

  Widget _tableHeader(OmpTokens tokens, List<String> cells) => Padding(
    padding: const EdgeInsets.only(top: OmpMetrics.s3, bottom: OmpMetrics.s1),
    child: _LedgerColumns(
      flexes: _cellFlexes.sublist(0, cells.length),
      cells: [
        for (final c in cells)
          Text(
            c,
            style: TextStyle(
              color: tokens.ink3,
              fontSize: OmpMetrics.fsXs,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    ),
  );

  Widget _ledgerRow(
    OmpTokens tokens, {
    required Key key,
    required String prime,
    String? sub,
    required List<String> cells,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: OmpMetrics.s1),
    child: _LedgerColumns(
      flexes: _cellFlexes.sublist(0, cells.length + 1),
      cells: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              prime,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tokens.ink, fontSize: OmpMetrics.fsSm),
            ),
            if (sub != null && sub.isNotEmpty)
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsXs),
              ),
          ],
        ),
        for (final c in cells)
          Text(
            c,
            style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsXs),
          ),
      ],
    ),
  );

  /// shortDate from UsageView, kept keyed off the gateway's ISO dates so no
  /// device-local re-derivation can drift across timezones or DST.
  static String _shortDate(String iso) {
    final parts = iso.split('-');
    if (parts.length < 3) return iso;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (m == null || d == null || m < 1 || m > 12) return iso;
    return '${months[m - 1]} $d';
  }
}

/// One row of the per-model / per-session tables: a wide first column and
/// right-aligned numeric cells, laid out with flexes so 360dp at 1.3 text
/// scale never overflows.
class _LedgerColumns extends StatelessWidget {
  const _LedgerColumns({required this.flexes, required this.cells});

  final List<int> flexes;
  final List<Widget> cells;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: i < flexes.length ? flexes[i] : 2,
            child: Align(
              alignment: i == 0 ? Alignment.centerLeft : Alignment.centerRight,
              child: cells[i],
            ),
          ),
      ],
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsXs),
            ),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tokens.ink,
                fontSize: OmpMetrics.fsBase,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: OmpMetrics.s1),
        Text(
          label,
          style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsXs),
        ),
      ],
    );
  }
}

/// Full-width segmented day-range picker, matching the pattern in
/// appearance_page.dart.
class _RangePicker extends StatelessWidget {
  const _RangePicker({super.key, required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final radius = BorderRadius.circular(OmpMetrics.radiusMd);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: tokens.lineStrong),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _ledgerRanges.length; i++) ...[
                if (i > 0)
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: tokens.lineStrong,
                  ),
                Expanded(
                  child: InkWell(
                    key: ValueKey('ledger-range-${_ledgerRanges[i]}'),
                    onTap: () => onChanged(_ledgerRanges[i]),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: OmpMetrics.s2,
                      ),
                      color: _ledgerRanges[i] == value
                          ? tokens.accentSoft
                          : Colors.transparent,
                      alignment: Alignment.center,
                      child: Text(
                        '${_ledgerRanges[i]}d',
                        style: TextStyle(
                          color: _ledgerRanges[i] == value
                              ? tokens.accent
                              : tokens.ink2,
                          fontSize: OmpMetrics.fsSm,
                          fontWeight: _ledgerRanges[i] == value
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
