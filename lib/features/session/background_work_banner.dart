// Idle-but-not-done banner: omp still has background jobs (async task
// subagents, async bash) that will wake the session on their own when they
// finish, so pressing Stop on the turn was not enough. Shown above the
// composer while the session is idle; the 'Stop session' button runs the
// shared stop-session flow (DELETE the gateway session).
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class BackgroundWorkBanner extends StatelessWidget {
  const BackgroundWorkBanner({super.key, required this.onStop});

  /// Runs the shared confirm-and-stop-session flow.
  final VoidCallback onStop;

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
              // button would otherwise squeeze the message off a 360dp
              // screen.
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onStop,
                  child: const Text('Stop session'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
