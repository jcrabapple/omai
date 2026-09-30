// The plan sheet: plan tab (progress, phases, tasks with per-status rows and
// expandable blocker text) plus an activity tab listing currently running
// tools. Ported from web/src/components/PlanPanel.svelte.
//
// No double-marking: a row's look is keyed on its own single status and the
// active task is picked with exclusive priority (in_progress, pending,
// blocked), so a completed task is never also shown as current.
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../transcript/items.dart';
import '../../transcript/plan.dart';

/// Opens the plan as a modal bottom sheet.
Future<void> showPlanSheet(
  BuildContext context, {
  required List<TodoPhase> phases,
  required List<ToolItem> runningTools,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // A scroll-controlled sheet may grow to full height; without this it
    // slides under the status bar (edge-to-edge is on by default).
    useSafeArea: true,
    builder: (sheetContext) => Material(
      color: Theme.of(sheetContext).extension<OmpTokens>()!.surface,
      child: PlanPanel(phases: phases, runningTools: runningTools),
    ),
  );
}

class PlanPanel extends StatefulWidget {
  const PlanPanel({
    super.key,
    required this.phases,
    required this.runningTools,
  });

  final List<TodoPhase> phases;
  final List<ToolItem> runningTools;

  @override
  State<PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends State<PlanPanel> {
  // Task ids are optional in the wire capture, so the fallback key is
  // positional (web: taskKey).
  String _taskKey(int phaseIndex, int taskIndex, TodoTask t) =>
      t.id ?? 'p$phaseIndex-t$taskIndex';

  /// Blocker rows are the only interactive affordance: tap toggles the text.
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final hasPlan = countTotal(widget.phases) > 0;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: DefaultTabController(
          length: 2,
          initialIndex: hasPlan ? 0 : 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TabBar(
                key: const ValueKey('plan-tabs'),
                labelColor: tokens.ink,
                unselectedLabelColor: tokens.ink3,
                indicatorColor: tokens.accent,
                dividerColor: tokens.line,
                tabs: [
                  Tab(
                    key: const ValueKey('plan-tab-plan'),
                    child: Text(
                      hasPlan
                          ? 'Plan ${countDone(widget.phases)}/${countTotal(widget.phases)}'
                          : 'Plan',
                    ),
                  ),
                  const Tab(
                    key: ValueKey('plan-tab-activity'),
                    text: 'Activity',
                  ),
                ],
              ),
              Flexible(
                child: TabBarView(
                  children: [
                    hasPlan ? _planPane(tokens) : _emptyPlan(tokens),
                    _activityPane(tokens),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyPlan(OmpTokens t) => Padding(
    padding: const EdgeInsets.all(OmpMetrics.s3),
    child: Text(
      'No plan in this session.',
      style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm),
    ),
  );

  Widget _planPane(OmpTokens t) {
    final total = countTotal(widget.phases);
    final done = countDone(widget.phases);
    return SingleChildScrollView(
      key: const ValueKey('plan-pane-plan'),
      padding: const EdgeInsets.all(OmpMetrics.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: 'Plan progress',
            child: Text(
              '$done of $total complete',
              style: TextStyle(color: t.ink2, fontSize: OmpMetrics.fsSm),
            ),
          ),
          const SizedBox(height: OmpMetrics.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              key: const ValueKey('plan-progress'),
              minHeight: 4,
              value: total == 0 ? 0 : done / total,
              backgroundColor: t.inset,
              color: t.accent,
            ),
          ),
          for (var pi = 0; pi < widget.phases.length; pi++)
            _phaseSection(pi, widget.phases[pi], t),
        ],
      ),
    );
  }

  Widget _phaseSection(int phaseIndex, TodoPhase phase, OmpTokens t) {
    return Padding(
      padding: const EdgeInsets.only(top: OmpMetrics.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (phase.name != null)
            Text(
              phase.name!,
              style: TextStyle(
                color: t.ink3,
                fontSize: OmpMetrics.fsXs,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          const SizedBox(height: OmpMetrics.s1),
          for (var ti = 0; ti < phase.tasks.length; ti++)
            _taskRow(phaseIndex, ti, phase.tasks[ti], t),
        ],
      ),
    );
  }

  Widget _taskRow(int phaseIndex, int taskIndex, TodoTask task, OmpTokens t) {
    final key = _taskKey(phaseIndex, taskIndex, task);
    final blocked = task.status == 'blocked';
    final hasBlocker = blocked && task.blocker != null;
    final expanded = _expanded.contains(key);

    final Widget lead;
    if (task.status == 'completed') {
      lead = Icon(Icons.check, size: 14, color: t.ok);
    } else if (task.status == 'in_progress') {
      lead = Icon(Icons.adjust, size: 14, color: t.accent);
    } else {
      lead = Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: t.ink3, width: 1.5),
        ),
      );
    }

    final content = Row(
      children: [
        lead,
        const SizedBox(width: OmpMetrics.s2),
        Expanded(
          child: Text(
            task.content,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: task.status == 'in_progress'
                  ? t.ink
                  : (task.status == 'completed' ? t.ink3 : t.ink2),
              fontSize: OmpMetrics.fsSm,
              decoration: task.status == 'completed'
                  ? TextDecoration.lineThrough
                  : null,
            ),
          ),
        ),
        if (blocked)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: OmpMetrics.s2,
              vertical: 1,
            ),
            decoration: BoxDecoration(
              color: t.warn.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Blocked',
              style: TextStyle(
                color: t.warn,
                fontSize: OmpMetrics.fsXs,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: OmpMetrics.s1),
      child: content,
    );

    return Column(
      key: ValueKey('task-$key'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasBlocker)
          // Blocked rows are the only interactive affordance.
          InkWell(
            key: ValueKey('blocker-toggle-$key'),
            onTap: () => setState(
              () => expanded ? _expanded.remove(key) : _expanded.add(key),
            ),
            borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
              child: row,
            ),
          )
        else
          row,
        if (hasBlocker && expanded)
          Padding(
            key: ValueKey('blocker-text-$key'),
            padding: const EdgeInsets.only(
              left: OmpMetrics.s6,
              bottom: OmpMetrics.s1,
            ),
            child: Text(
              task.blocker!,
              style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm),
            ),
          ),
      ],
    );
  }

  Widget _activityPane(OmpTokens t) {
    final tools = widget.runningTools;
    return ListView(
      key: const ValueKey('plan-pane-activity'),
      shrinkWrap: true,
      padding: const EdgeInsets.all(OmpMetrics.s3),
      children: tools.isEmpty
          ? [
              Text(
                'No tools running',
                style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm),
              ),
            ]
          : [
              for (final tool in tools)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: OmpMetrics.s1),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: t.accent,
                        ),
                      ),
                      const SizedBox(width: OmpMetrics.s2),
                      Text(
                        tool.toolName,
                        style: TextStyle(
                          color: t.ink,
                          fontSize: OmpMetrics.fsSm,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: OmpMetrics.s2),
                      Expanded(
                        child: Text(
                          tool.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.ink3,
                            fontSize: OmpMetrics.fsSm,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
    );
  }
}
