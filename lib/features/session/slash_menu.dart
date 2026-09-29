// Slash command menu, ported from web/src/components/SlashMenu.svelte.
// Grouped options with 48dp rows; keyboard/touch selection by flat index.

import 'package:flutter/material.dart';

import '../../composer/slash.dart';
import '../../theme/tokens.dart';

class SlashMenu extends StatelessWidget {
  const SlashMenu({
    super.key,
    required this.groups,
    required this.active,
    required this.onPick,
    required this.onHover,
  });

  final List<SlashGroup> groups;
  final int active;
  final void Function(SlashMatch match) onPick;
  final void Function(int index) onHover;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final children = <Widget>[];
    var i = 0;
    for (final g in groups) {
      children.add(Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: OmpMetrics.s3, vertical: OmpMetrics.s1),
        child: Text(g.label.toUpperCase(),
            style: TextStyle(
                color: tokens.ink3,
                fontSize: OmpMetrics.fsXs,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
      ));
      for (final m in g.items) {
        final idx = i++;
        children.add(InkResponse(
          onTap: () => onPick(m),
          onHover: (_) => onHover(idx),
          child: Container(
            constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(
                horizontal: OmpMetrics.s3, vertical: OmpMetrics.s1),
            color: idx == active ? tokens.press : null,
            child: Row(
              children: [
                Text('/${m.command.name}',
                    style: TextStyle(
                        color: tokens.ink,
                        fontSize: OmpMetrics.fsBase,
                        fontFamily: 'monospace')),
                if (m.command.inputHint != null) ...[
                  const SizedBox(width: OmpMetrics.s3),
                  Text(m.command.inputHint!,
                      style: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsSm,
                          fontFamily: 'monospace')),
                ],
                const Spacer(),
                Flexible(
                  child: Text(firstDescriptionLine(m.command),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: tokens.ink3, fontSize: OmpMetrics.fsSm)),
                ),
              ],
            ),
          ),
        ));
      }
    }
    return Material(
      color: tokens.surface,
      borderRadius: BorderRadius.circular(OmpMetrics.radiusLg),
      elevation: 4,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}
