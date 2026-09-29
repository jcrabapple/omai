// Right-aligned user message bubble with send-state notes. Ported from
// web/src/components/items/UserBubble.svelte.
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../transcript/items.dart';
import 'message_actions.dart';

const Map<UserNote, String> _noteLabels = {
  'steer': 'Steered',
  'steer-pending': 'Sent while streaming',
  'queued': 'Queued',
  'other-client': 'From another device',
};

class UserBubble extends StatelessWidget {
  final UserItem item;

  const UserBubble({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Widget bubble = Container(
      padding: const EdgeInsets.symmetric(
          horizontal: OmpMetrics.s4, vertical: OmpMetrics.s2),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(OmpMetrics.radiusLg),
          topRight: Radius.circular(OmpMetrics.radiusLg),
          bottomLeft: Radius.circular(OmpMetrics.radiusSm),
          bottomRight: Radius.circular(OmpMetrics.radiusLg),
        ),
        border: item.failed == true ? Border.all(color: t.err) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.text.isNotEmpty)
            SelectionArea(
              child: Text(
                item.text,
                style: textTheme.bodyMedium?.copyWith(color: cs.onSurface),
              ),
            ),
          if (item.images > 0)
            Padding(
              padding: const EdgeInsets.only(top: OmpMetrics.s1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_outlined,
                      size: 14, color: t.ink3),
                  const SizedBox(width: OmpMetrics.s1),
                  Text(
                    '${item.images} ${item.images == 1 ? 'image' : 'images'}',
                    style: TextStyle(
                        color: t.ink3, fontSize: OmpMetrics.fsSm),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (item.pending) {
      bubble = Opacity(opacity: 0.6, child: bubble);
    }

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Short messages hug their content: cap the width at 85% of the
            // available space instead of forcing exactly 85%.
            LayoutBuilder(
              builder: (context, constraints) => Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.85,
                  ),
                  child: MessageActions(
                    text: item.text,
                    raw: item.raw,
                    label: 'Your message',
                    child: bubble,
                  ),
                ),
              ),
            ),
            if (item.failed == true)
              _Note(
                text:
                    'Not sent${item.error != null ? ': ${item.error}' : ''}',
                color: t.err,
                stale: item.stale == true,
              )
            else if (item.pending && item.note == 'steer-pending')
              const _Note(text: 'pending')
            else if (item.note == 'queued')
              _Note(text: 'Queued', stale: item.stale == true)
            else if (item.pending)
              const _Note(text: 'Sending')
            else if (item.note != null && _noteLabels[item.note!] != null)
              _Note(text: _noteLabels[item.note!]!, stale: item.stale == true),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final Color? color;
  final bool stale;

  const _Note({required this.text, this.color, this.stale = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    Widget note = Text(
      text,
      style: TextStyle(color: color ?? t.ink3, fontSize: OmpMetrics.fsXs),
    );
    if (stale) note = Opacity(opacity: 0.7, child: note);
    return Padding(
      padding: const EdgeInsets.only(top: OmpMetrics.s1),
      child: note,
    );
  }
}
