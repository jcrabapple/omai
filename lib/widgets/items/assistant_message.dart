// Assistant message: full-width markdown with selectable text, monospace code
// blocks with horizontal scroll, no syntax highlighting in v1. Ported from
// web/src/components/items/AssistantMessage.svelte (web's highlight.js code
// headers and copy buttons arrive with a later task).
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../theme/tokens.dart';
import '../../transcript/items.dart';
import 'message_actions.dart';

MarkdownStyleSheet _sheet(BuildContext context, OmpTokens t) {
  final base = Theme.of(context).textTheme;
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: base.bodyMedium?.copyWith(color: t.ink),
    h1: base.titleLarge?.copyWith(color: t.ink),
    h2: base.titleMedium?.copyWith(color: t.ink),
    h3: base.titleSmall?.copyWith(color: t.ink),
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: OmpMetrics.fsSm,
      color: t.ink,
    ),
    codeblockDecoration: BoxDecoration(
      color: t.inset,
      borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
      border: Border.all(color: t.line),
    ),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: t.lineStrong)),
      color: t.inset,
    ),
    a: TextStyle(color: t.accent, decoration: TextDecoration.underline),
    tableBorder: TableBorder.all(color: t.line),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: t.line)),
    ),
  );
}

class AssistantMessage extends StatelessWidget {
  final AssistantItem item;

  /// Called when the user taps a link. v1 opens nothing (TODO: in-app viewer).
  final void Function(String href)? onLinkTap;

  const AssistantMessage({super.key, required this.item, this.onLinkTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final stopped = item.stopReason == 'aborted' && !item.streaming;
    final visible = item.streaming ||
        item.text.trim().isNotEmpty ||
        (item.error != null) ||
        stopped;
    if (!visible) return const SizedBox.shrink();

    return MessageActions(
      text: item.text,
      raw: item.raw,
      disabled: item.streaming,
      label: 'Assistant message',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionArea(
            child: MarkdownBody(
              data: item.text,
              selectable: false,
              styleSheet: _sheet(context, t),
              onTapLink: (text, href, title) {
                // TODO(D2): open links in an in-app viewer. Deliberately a
                // no-op so taps never crash before that lands.
                onLinkTap?.call(href ?? text);
              },
            ),
          ),
          if (stopped)
            Padding(
              padding: const EdgeInsets.only(top: OmpMetrics.s2),
              child: Text('Stopped',
                  style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm)),
            ),
          if (item.error != null)
            Padding(
              padding: const EdgeInsets.only(top: OmpMetrics.s2),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 13, color: t.err),
                  const SizedBox(width: OmpMetrics.s1),
                  Flexible(
                    child: Text(item.error!,
                        style: TextStyle(
                            color: t.err, fontSize: OmpMetrics.fsSm)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
