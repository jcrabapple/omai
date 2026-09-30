// Stacked daily token bar chart for the usage ledger, ported from the SVG
// chart in web UsageView.svelte: one slot per day (bars narrow as the range
// grows, so 90d does not squash), input and output stacked, scaled to the
// tallest day. Drawn with CustomPaint so the ledger needs no new
// dependencies. Accessibility lives in the parent: a Semantics node
// summarises the range and cost so the chart is not a TalkBack black hole.

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'usage_ledger.dart';

class LedgerBarChart extends StatelessWidget {
  const LedgerBarChart({super.key, required this.days});

  final List<LedgerDay> days;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return SizedBox(
      key: const ValueKey('ledger-chart'),
      height: 96,
      width: double.infinity,
      child: CustomPaint(
        painter: _LedgerChartPainter(
          days: days,
          inColor: tokens.accent,
          outColor: tokens.ink3,
        ),
      ),
    );
  }
}

class _LedgerChartPainter extends CustomPainter {
  _LedgerChartPainter({
    required this.days,
    required this.inColor,
    required this.outColor,
  });

  final List<LedgerDay> days;
  final Color inColor;
  final Color outColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    var max = 1.0;
    for (final d in days) {
      final v = d.input + d.output;
      if (v > max) max = v;
    }
    final slot = size.width / days.length;
    // 7px of a 10px slot on the web, as a fraction here so 90d stays legible.
    final barW = (slot * 0.7).clamp(1.0, 14.0);
    final paintIn = Paint()..color = inColor;
    final paintOut = Paint()..color = outColor;
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      final x = i * slot + (slot - barW) / 2;
      final hIn = (d.input / max) * size.height;
      final hOut = (d.output / max) * size.height;
      if (hIn > 0) {
        canvas.drawRect(
          Rect.fromLTWH(x, size.height - hIn, barW, hIn),
          paintIn,
        );
      }
      if (hOut > 0) {
        canvas.drawRect(
          Rect.fromLTWH(x, size.height - hIn - hOut, barW, hOut),
          paintOut,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LedgerChartPainter oldDelegate) =>
      oldDelegate.days != days ||
      oldDelegate.inColor != inColor ||
      oldDelegate.outColor != outColor;
}
