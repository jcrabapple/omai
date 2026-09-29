// Compact plan ribbon under the session header while the session has todo
// phases: progress (n/m) plus the current task, tinted when it is blocked.
// Tapping opens the PlanPanel sheet. Ported from
// web/src/components/PlanRibbon.svelte (narrow-screen path: the plan always
// opens as a sheet).
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../transcript/plan.dart';

/// Clipped task text on the ribbon, matching the web's 60-character clip.
@visibleForTesting
String clipTask(String content) =>
    content.length > 60 ? '${content.substring(0, 60)}…' : content;

class PlanRibbon extends StatelessWidget {
  const PlanRibbon({super.key, required this.phases, this.onOpen});

  final List<TodoPhase> phases;

  /// Opens the plan panel (a bottom sheet on this form factor).
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final total = countTotal(phases);
    if (total == 0) return const SizedBox.shrink();
    final done = countDone(phases);
    final active = pickActiveTask(phases);
    final allDone = done == total;
    final blocked = active?.status == 'blocked';
    final accent = blocked ? tokens.warn : tokens.accent;

    final label = allDone ? 'All tasks complete' : 'Plan $done/$total';
    final task = allDone || active == null ? null : clipTask(active.content);

    return Semantics(
      label:
          'Session plan: $label${task == null ? '' : ', current task $task'}',
      button: true,
      child: Material(
        color: tokens.inset,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: tokens.line),
              borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: OmpMetrics.s3,
              vertical: OmpMetrics.s2,
            ),
            child: Row(
              children: [
                Icon(
                  allDone ? Icons.check_circle_outline : Icons.adjust,
                  size: 14,
                  color: accent,
                ),
                const SizedBox(width: OmpMetrics.s2),
                Text(
                  label,
                  style: TextStyle(
                    color: tokens.ink2,
                    fontSize: OmpMetrics.fsSm,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
                if (task != null) ...[
                  const SizedBox(width: OmpMetrics.s2),
                  Expanded(
                    child: Text(
                      task,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: blocked ? tokens.warn : tokens.ink3,
                        fontSize: OmpMetrics.fsSm,
                      ),
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
}
