// Idle-but-not-done banner: omp still has background jobs (async task
// subagents, async bash) that will wake the session on their own when they
// finish, so pressing Stop on the turn was not enough. Shown above the
// composer while the session is idle; the 'Stop session' button runs the
// shared stop-session flow (DELETE the gateway session) and 'Show agents'
// opens the live subagent roster.
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class BackgroundWorkBanner extends StatelessWidget {
  const BackgroundWorkBanner({
    super.key,
    required this.onStop,
    this.onShowAgents,
  });

  /// Runs the shared confirm-and-stop-session flow.
  final VoidCallback onStop;

  /// Opens the agents sheet; null hides the button.
  final VoidCallback? onShowAgents;

  @override
  Widget build(BuildContext context) {
    const message =
        'Background work is still running. When it finishes, the agent will '
        'start again.';
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Semantics(
      container: true,
      label: message,
      child: Material(
        color: tokens.inset,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.line),
            borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: OmpMetrics.s3,
            vertical: OmpMetrics.s2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.hourglass_top, size: 16, color: tokens.warn),
                  const SizedBox(width: OmpMetrics.s2),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(
                        color: tokens.ink2,
                        fontSize: OmpMetrics.fsSm,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: OmpMetrics.s2),
              // Under the message, not beside it: at large text scales the
              // buttons would otherwise squeeze the message off a 360dp
              // screen. Wrap, not Row, so two buttons can stack at 1.3x.
              Wrap(
                alignment: WrapAlignment.end,
                spacing: OmpMetrics.s2,
                children: [
                  if (onShowAgents != null)
                    TextButton(
                      key: const ValueKey('banner-show-agents'),
                      onPressed: onShowAgents,
                      child: const Text('Show agents'),
                    ),
                  TextButton(
                    onPressed: onStop,
                    child: const Text('Stop session'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
