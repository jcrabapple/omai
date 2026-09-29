// Session header, ported from web/src/components/SessionHeader.svelte +
// ContextMeter.svelte + ConnectionDot.svelte. Name, cwd, model chip, context
// meter, cost, connection state; and while a turn runs, a live activity line
// (current tool + elapsed, ticking each second) so a long turn never reads
// as a hang.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../format.dart';
import '../../api/models.dart' show SessionInfo;
import '../../state/session_controller.dart';
import '../../stream/session_stream.dart' show StreamState, StreamStatus;
import '../../theme/tokens.dart';
import 'context_meter.dart';

class SessionHeader extends ConsumerWidget implements PreferredSizeWidget {
  const SessionHeader({super.key, required this.gwId});

  final String gwId;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 26);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = ref.watch(sessionControllerProvider(gwId));
    final info = state.info;

    // Cost prefers the fresher /stats payload (web: active.stats.cost).
    final statsCost = state.stats?['cost'];
    final cost = statsCost is num ? money(statsCost.toDouble()) : null;
    final model = info?.model?.displayName ?? '';

    return AppBar(
      backgroundColor: tokens.canvas,
      foregroundColor: tokens.ink,
      elevation: 0,
      toolbarHeight: kToolbarHeight + 26,
      leading: const BackButton(),
      titleSpacing: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            info?.title ?? 'Session',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: tokens.ink,
                fontSize: OmpMetrics.fsLg,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 18,
            child: Row(
              children: [
                if (model.isNotEmpty) ...[
                  Flexible(
                    child: Text(model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: tokens.ink3, fontSize: OmpMetrics.fsXs)),
                  ),
                  const SizedBox(width: OmpMetrics.s3),
                ],
                _ContextMeterFromState(
                    info: info, stats: state.stats),
                if (cost != null) ...[
                  const SizedBox(width: OmpMetrics.s3),
                  Text(cost,
                      style: TextStyle(
                          color: tokens.ink2, fontSize: OmpMetrics.fsXs)),
                ],
                const SizedBox(width: OmpMetrics.s3),
                ConnectionDot(status: state.connection),
              ],
            ),
          ),
        ],
      ),
      bottom: state.activity != null
          ? PreferredSize(
              preferredSize: const Size.fromHeight(22),
              child: Padding(
                padding: const EdgeInsets.only(
                    left: OmpMetrics.s4, bottom: OmpMetrics.s1),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ActivityLine(activity: state.activity!),
                ),
              ),
            )
          : null,
    );
  }
}

/// Reads context usage the way the web header does: /stats first, info as a
/// fallback.
class _ContextMeterFromState extends StatelessWidget {
  const _ContextMeterFromState({required this.info, required this.stats});

  final SessionInfo? info;
  final Map<String, Object?>? stats;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    double? percent;
    int? tokensUsed;
    int? window;
    final cu = stats?['contextUsage'];
    if (cu is Map) {
      final p = cu['percent'];
      if (p is num) percent = p.toDouble();
      final t = cu['tokens'];
      if (t is num) tokensUsed = t.toInt();
      final w = cu['contextWindow'];
      if (w is num) window = w.toInt();
    } else if (info != null) {
      final usage = info.contextUsage;
      percent = usage?.percent;
      tokensUsed = usage?.tokens;
      window = usage?.contextWindow;
    }
    return ContextMeter(
        percent: percent, tokens: tokensUsed, window: window);
  }
}

/// Connection dot + text: live / connecting / retrying with a countdown /
/// offline. Ported from ConnectionDot.svelte plus the header's connectionText.
class ConnectionDot extends StatefulWidget {
  const ConnectionDot({super.key, required this.status});

  final StreamStatus status;

  @override
  State<ConnectionDot> createState() => _ConnectionDotState();
}

class _ConnectionDotState extends State<ConnectionDot> {
  Timer? _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ConnectionDot old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  void _syncTicker() {
    final retrying = widget.status.state == StreamState.retrying;
    if (retrying && _ticker == null) {
      _now = DateTime.now();
      _ticker =
          Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() => _now = DateTime.now());
      });
    } else if (!retrying && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  (Color, String) _resolve(OmpTokens t) {
    switch (widget.status.state) {
      case StreamState.live:
        return (t.ok, '');
      case StreamState.connecting:
        return (t.warn, 'Connecting');
      case StreamState.retrying:
        if (widget.status.message?.isNotEmpty == true) {
          return (t.warn, widget.status.message!);
        }
        final retryAt = widget.status.retryAt;
        final s = retryAt == null
            ? 0
            : retryAt - _now.millisecondsSinceEpoch;
        return (t.warn,
            s > 0 ? 'Reconnecting in ${(s / 1000).ceil()} s' : 'Reconnecting');
      case StreamState.offline:
      case StreamState.gone:
        return (t.err, 'Offline');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final (color, text) = _resolve(tokens);
    return Semantics(
      label: text.isEmpty ? 'Connected' : text,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(width: OmpMetrics.s1),
            Text(text,
                style: TextStyle(
                    color: tokens.ink3, fontSize: OmpMetrics.fsXs)),
          ],
        ],
      ),
    );
  }
}

/// The live activity line: current tool name + elapsed since the turn
/// started, ticking each second. Gone the moment agent_end lands (the
/// controller clears `activity`).
class ActivityLine extends StatefulWidget {
  const ActivityLine({super.key, required this.activity});

  final ActivitySummary activity;

  @override
  State<ActivityLine> createState() => _ActivityLineState();
}

class _ActivityLineState extends State<ActivityLine> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final elapsedMs =
        DateTime.now().millisecondsSinceEpoch - widget.activity.turnStartedAt;
    final tool = widget.activity.toolName;
    final text = [
      if (tool.isNotEmpty) tool,
      duration(elapsedMs),
    ].where((p) => p.isNotEmpty).join(' · ');
    return Semantics(
      label: 'Working: $text',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: tokens.accent),
          ),
          const SizedBox(width: OmpMetrics.s2),
          Text(text,
              style: TextStyle(
                  color: tokens.ink2, fontSize: OmpMetrics.fsXs)),
        ],
      ),
    );
  }
}
