// Session info sheet, opened by tapping the header title: where the session
// runs, its model and thinking level (both switchable), context usage, cost,
// and a "Stats for nerds" collapsible with the last turn's TTFT, tokens per
// second, stream reconnect count and last event seq. Ported from
// web/src/components/SessionInfoSheet.svelte (the queue/protocol section
// stays web-side: it reads a dashboard-only /state shape).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../format.dart';
import '../../state/session_controller.dart';
import '../../theme/tokens.dart';
import '../../widgets/model_picker.dart';

/// The thinking levels the gateway accepts, off first (docs/API.md).
const thinkingLevels = <String>['off', 'minimal', 'low', 'medium', 'high'];

Future<void> showSessionInfoSheet(
  BuildContext context, {
  required String gwId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) => Material(
        color: Theme.of(sheetContext).extension<OmpTokens>()!.surface,
        child: SessionInfoSheet(gwId: gwId),
      ),
    ),
  );
}

class SessionInfoSheet extends ConsumerWidget {
  const SessionInfoSheet({super.key, required this.gwId});

  final String gwId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = ref.watch(sessionControllerProvider(gwId));
    final info = state.info;
    final stats = state.stats;
    final model = info?.model;

    final usage = _contextUsage(state);
    final statsCost = stats?['cost'];
    final cost = statsCost is num ? money(statsCost.toDouble()) : null;
    final turnStats = state.turnStats;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(OmpMetrics.s4),
          // Selectable so paths and ids can also be selection-copied longhand
          // (review #12); the copy buttons above are the one-tap path.
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Session info',
                  style: TextStyle(
                    color: tokens.ink,
                    fontSize: OmpMetrics.fsLg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (info == null) ...[
                  const SizedBox(height: OmpMetrics.s3),
                  Text(
                    'No session is open.',
                    style: TextStyle(
                      color: tokens.ink3,
                      fontSize: OmpMetrics.fsSm,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: OmpMetrics.s3),
                  _section(context, 'Where', [
                    _row(
                      context,
                      'Folder',
                      info.cwd,
                      tokens,
                      copyLabel: 'Copy folder path',
                    ),
                    _row(
                      context,
                      'Session',
                      info.gwId,
                      tokens,
                      copyLabel: 'Copy session id',
                    ),
                    if (info.ompSessionFile != null)
                      _row(
                        context,
                        'Session file',
                        info.ompSessionFile!,
                        tokens,
                        copyLabel: 'Copy session file path',
                      ),
                  ]),
                  _section(context, 'Model', [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 96,
                          child: Text(
                            'Model',
                            style: TextStyle(
                              color: tokens.ink3,
                              fontSize: OmpMetrics.fsSm,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            model == null ? 'Not set' : model.displayName,
                            style: TextStyle(
                              color: tokens.ink,
                              fontSize: OmpMetrics.fsSm,
                            ),
                          ),
                        ),
                        Semantics(
                          label: 'Switch model',
                          button: true,
                          child: TextButton(
                            onPressed: () => _switchModel(context, ref),
                            child: Text(
                              'Change',
                              style: TextStyle(
                                color: tokens.accent,
                                fontSize: OmpMetrics.fsSm,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: OmpMetrics.s2,
                      ),
                      child: Wrap(
                        spacing: OmpMetrics.s2,
                        runSpacing: OmpMetrics.s2,
                        children: [
                          for (final level in thinkingLevels)
                            _thinkingChip(
                              context,
                              ref,
                              level,
                              info.thinkingLevel ?? 'off',
                            ),
                        ],
                      ),
                    ),
                    _row(
                      context,
                      'Context',
                      usage == null
                          ? 'Not reported yet'
                          : '${usage.tokens != null ? "${compactNumber(usage.tokens!)} of " : ""}'
                                '${compactNumber(usage.contextWindow)} tokens',
                      tokens,
                    ),
                  ]),
                  _section(context, 'Usage', [
                    _row(context, 'Cost', cost ?? '\$0.00', tokens),
                    _row(context, 'Messages', '${info.messageCount}', tokens),
                  ]),
                  Theme(
                    data: Theme.of(context)
                        .copyWith(dividerColor: const Color(0x00000000)),
                    child: ExpansionTile(
                      key: const ValueKey('stats-nerds'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(
                        bottom: OmpMetrics.s2,
                      ),
                      iconColor: tokens.ink3,
                      collapsedIconColor: tokens.ink3,
                      title: Text(
                        'Stats for nerds',
                        style: TextStyle(
                          color: tokens.ink2,
                          fontSize: OmpMetrics.fsSm,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      children: [
                        _row(
                          context,
                          'Time to first token',
                          turnStats?.ttftMs == null
                              ? 'No turn yet'
                              : duration(turnStats!.ttftMs),
                          tokens,
                        ),
                        _row(
                          context,
                          'Tokens per second',
                          turnStats?.tokensPerSec == null
                              ? 'Not reported'
                              : '${turnStats!.tokensPerSec!.toStringAsFixed(1)} tok/s',
                          tokens,
                        ),
                        _row(
                          context,
                          'Stream reconnects',
                          '${turnStats?.reconnects ?? state.streamReconnects}',
                          tokens,
                        ),
                        _row(
                          context,
                          'Last event seq',
                          '${turnStats?.lastEventSeq ?? info.lastEventSeq}',
                          tokens,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  ContextUsageView? _contextUsage(SessionState state) {
    final cu = state.stats?['contextUsage'];
    if (cu is Map) {
      return ContextUsageView(
        percent: cu['percent'] is num
            ? (cu['percent'] as num).toDouble()
            : null,
        tokens: cu['tokens'] is num ? (cu['tokens'] as num).toInt() : null,
        contextWindow: cu['contextWindow'] is num
            ? (cu['contextWindow'] as num).toInt()
            : 0,
      );
    }
    final u = state.info?.contextUsage;
    if (u == null) return null;
    return ContextUsageView(
      percent: u.percent,
      tokens: u.tokens,
      contextWindow: u.contextWindow,
    );
  }

  Future<void> _switchModel(BuildContext context, WidgetRef ref) async {
    final info = ref.read(sessionControllerProvider(gwId)).info;
    final m = info?.model;
    await showModelPickerSheet(
      context,
      ref,
      current: m == null ? null : CurrentModel(provider: m.provider, id: m.id),
      onPick: (picked) {
        if (picked == null) return;
        ref
            .read(sessionControllerProvider(gwId).notifier)
            .setModel(picked.provider, picked.id);
      },
    );
  }

  Widget _thinkingChip(
    BuildContext context,
    WidgetRef ref,
    String level,
    String current,
  ) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final active = current == level;
    return Semantics(
      label: 'Thinking level $level',
      button: true,
      child: InkWell(
        onTap: () {
          ref.read(sessionControllerProvider(gwId).notifier).setThinking(level);
        },
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
          padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: active ? tokens.accent : tokens.line),
            color: active ? tokens.accent.withValues(alpha: 0.15) : null,
          ),
          child: Text(
            level,
            style: TextStyle(
              color: active ? tokens.accent : tokens.ink2,
              fontSize: OmpMetrics.fsSm,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> rows) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: OmpMetrics.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tokens.ink3,
              fontSize: OmpMetrics.fsXs,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: OmpMetrics.s1),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value,
    OmpTokens t, {
    String? copyLabel,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OmpMetrics.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: t.ink, fontSize: OmpMetrics.fsSm),
            ),
          ),
          if (copyLabel != null)
            IconButton(
              tooltip: copyLabel,
              icon: Icon(Icons.copy, size: 18, color: t.ink3),
              // 48dp target; the button hugs the row without growing it.
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: OmpMetrics.hit,
                minHeight: OmpMetrics.hit,
              ),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(
                    content: Text('Copied'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Plain view of context usage resolved the way the header does (/stats
/// first, info as fallback).
class ContextUsageView {
  const ContextUsageView({
    required this.percent,
    required this.tokens,
    required this.contextWindow,
  });

  final double? percent;
  final int? tokens;
  final int contextWindow;
}
