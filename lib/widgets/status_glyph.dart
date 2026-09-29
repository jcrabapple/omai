// Session status dot / flag, ported from web/src/components/StatusGlyph.svelte.
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

typedef SessionStatus = String; // 'needs' | 'review' | 'running' | 'idle'

const Map<SessionStatus, String> statusLabels = {
  'needs': 'Needs you',
  'review': 'Ready for review',
  'running': 'Running',
  'idle': 'Idle',
};

/// 8px status dot; `review` becomes a flag icon. Announced via Semantics.
class StatusGlyph extends StatelessWidget {
  final SessionStatus status;

  const StatusGlyph({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final label = statusLabels[status] ?? status;
    final Widget glyph;
    if (status == 'review') {
      glyph = Icon(Icons.flag_outlined, size: 12, color: t.warn);
    } else {
      final Color fill;
      if (status == 'running') {
        fill = t.accent;
      } else if (status == 'needs') {
        fill = t.warn;
      } else {
        fill = t.canvas;
      }
      glyph = Container(
        width: 8,
        height: 8,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: status == 'idle' ? null : fill,
          border: status == 'idle' ? Border.all(color: t.ink3, width: 1.5) : null,
        ),
      );
    }
    return Semantics(
      label: label,
      child: ExcludeSemantics(child: glyph),
    );
  }
}
