// Card for `!` command output with ANSI colors. Ported from
// web/src/components/items/CommandCard.svelte.
import 'package:flutter/material.dart';

import '../../render/ansi.dart';
import '../../theme/tokens.dart';
import '../../transcript/items.dart';

class CommandCard extends StatelessWidget {
  final CommandItem item;

  const CommandCard({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final title = (item.command?.trim().isNotEmpty ?? false)
        ? item.command!.trim()
        : 'Command output';
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: OmpMetrics.fsSm,
      color: t.ink,
    );

    return Container(
      decoration: BoxDecoration(
        color: t.canvas,
        borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
        border: Border.all(color: t.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration:
                BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: OmpMetrics.s3, vertical: OmpMetrics.s2),
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: t.ink2,
                    fontSize: OmpMetrics.fsSm,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(OmpMetrics.s3),
              child: SelectionArea(
                child: Text.rich(
                  TextSpan(
                    children: ansiToSpans(item.text,
                        palette: ansiPalette(t), base: base),
                  ),
                  style: base,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
