// One transcript item rendered as the right widget. Ported from the web
// transcript's per-kind component switch. Takes plain data; grouping lives in
// the caller (a ToolsBlock's list goes to ToolGroup).
import 'package:flutter/material.dart';

import '../transcript/items.dart';
import 'items/assistant_message.dart';
import 'items/command_card.dart';
import 'items/notice_line.dart';
import 'items/skill_chip.dart';
import 'items/thinking_row.dart';
import 'items/tool_group.dart';
import 'items/user_bubble.dart';

/// Callbacks the screens wire up; everything defaults to a no-op so the
/// widgets stay plain-data.
class TranscriptItemCallbacks {
  final void Function(String href)? onLinkTap;
  final void Function(Object? raw)? onInspect;

  /// Retry a failed local send: called with the bubble's text.
  final void Function(UserItem item)? onRetrySend;

  /// True while that retry is in flight: the Retry button disables.
  final bool retryingSend;

  /// Fork the session at this message (user bubbles; hidden while a turn
  /// runs or the bubble is pending/failed/empty).
  final VoidCallback? onFork;

  const TranscriptItemCallbacks({
    this.onLinkTap,
    this.onInspect,
    this.onRetrySend,
    this.retryingSend = false,
    this.onFork,
  });
}

class TranscriptItemView extends StatelessWidget {
  final Item item;

  /// A run of consecutive tool calls; required only when [item] is a
  /// [ToolItem] (one row per call, grouped visually).
  final List<ToolItem>? toolRun;

  final TranscriptItemCallbacks callbacks;

  const TranscriptItemView({
    super.key,
    required this.item,
    this.toolRun,
    this.callbacks = const TranscriptItemCallbacks(),
  });

  @override
  Widget build(BuildContext context) {
    final it = item;
    if (it is UserItem) {
      return UserBubble(
        item: it,
        onRetry: callbacks.onRetrySend,
        retrying: callbacks.retryingSend,
        onInspect: callbacks.onInspect,
        onFork: callbacks.onFork,
      );
    }
    if (it is AssistantItem) {
      return AssistantMessage(
        item: it,
        onLinkTap: callbacks.onLinkTap,
        onInspect: callbacks.onInspect,
      );
    }
    if (it is ThinkingItem) return ThinkingRow(item: it);
    if (it is ToolItem) {
      return ToolGroup(tools: toolRun ?? [it], onInspect: callbacks.onInspect);
    }
    if (it is SkillItem) return SkillChip(item: it);
    if (it is CommandItem) return CommandCard(item: it);
    if (it is NoticeItem) return NoticeLine(item: it);
    return const SizedBox.shrink();
  }
}
