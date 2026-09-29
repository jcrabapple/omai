// Context meter, ported from web/src/components/ContextMeter.svelte. A 44px
// bar plus a percentage; fill and number turn amber from 70 %, red from 85 %
// (contextLevel from lib/format.dart).

import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/tokens.dart';

class ContextMeter extends StatelessWidget {
  const ContextMeter({
    super.key,
    required this.percent,
    this.tokens,
    this.window,
  });

  final double? percent;
  final int? tokens;
  final int? window;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final level = contextLevel(percent);
    final shown = percent == null
        ? null
        : (percent!.clamp(0, 100).round());
    final fill = switch (level) {
      'warn' => t.warn,
      'err' => t.err,
      _ => t.ink2,
    };

    return Semantics(
      label: 'Context used, ${shown == null ? 'unknown' : '$shown percent'}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 3,
            decoration: BoxDecoration(
              color: t.lineStrong,
              borderRadius: BorderRadius.circular(2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (shown ?? 0) / 100,
                child: Container(color: fill),
              ),
            ),
          ),
          const SizedBox(width: OmpMetrics.s1),
          Text(
            shown == null ? '–' : '$shown%',
            style: TextStyle(
              color: level == 'ok' ? t.ink3 : fill,
              fontSize: OmpMetrics.fsXs,
            ),
          ),
        ],
      ),
    );
  }
}