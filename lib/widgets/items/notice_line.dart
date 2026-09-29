// Centered system notice (compaction, retries). Ported from
// web/src/components/items/NoticeLine.svelte.
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../transcript/items.dart';

class NoticeLine extends StatelessWidget {
  final NoticeItem item;

  const NoticeLine({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final error = item.level == 'error';
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: OmpMetrics.s4, vertical: OmpMetrics.s1),
      child: Semantics(
        liveRegion: error,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (item.active == true)
              const Padding(
                padding: EdgeInsets.only(right: OmpMetrics.s2),
                child: SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            Flexible(
              child: Text(
                item.text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: error ? t.err : t.ink3,
                  fontSize: OmpMetrics.fsSm,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
