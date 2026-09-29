// Read-only pending-approval banner, shown while transcript.pendingUi is
// non-empty (ported from the web approval takeover; the buttons are D2).

import 'package:flutter/material.dart';

import '../../state/session_controller.dart' show UiRequestView;
import '../../theme/tokens.dart';

class PendingApprovalBanner extends StatelessWidget {
  const PendingApprovalBanner({super.key, required this.request});

  final UiRequestView request;

  // TODO(D2): wire Approve / Deny to controller.answerUi(request.id, ...) and
  // remove the "arrive in the next build" note. The handlers below are the
  // hook: the banner already sits where the composer's approval strip goes.
  void onApprove() {}
  void onDeny() {}

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final title = request.title ?? 'Approval requested';
    final summary = request.message ?? request.method;
    return Material(
      color: tokens.warnSoft,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: OmpMetrics.s4, vertical: OmpMetrics.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: TextStyle(
                      color: tokens.ink,
                      fontSize: OmpMetrics.fsBase,
                      fontWeight: FontWeight.w600)),
              if (summary.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(summary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: tokens.ink2, fontSize: OmpMetrics.fsSm)),
              ],
              const SizedBox(height: OmpMetrics.s1),
              Text('Approve and Deny arrive in the next build.',
                  style: TextStyle(
                      color: tokens.ink3, fontSize: OmpMetrics.fsXs)),
            ],
          ),
        ),
      ),
    );
  }
}
