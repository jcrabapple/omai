// Copy, fork, inspect and select for one message. Ported from
// web/src/components/items/MessageActions.svelte.
//
// Device review: on a phone the old SelectionArea toolbar hid the actions in
// the Android overflow, so a long-press anywhere on the bubble now opens the
// same menu the overflow button opens (the standard chat-app pattern), with
// haptic feedback. 'Select text' opens a bottom sheet where the message is a
// SelectableText, so a portion can still be copied. There is deliberately no
// SelectionArea under the bubble: a long-press recognizer with no selection
// recognizer underneath does not race (the earlier raw-pointer timer did).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps one message and offers Copy (of [text]), Inspect ([raw]) and an
/// optional [onRetry] action in the long-press and overflow menus.
class MessageActions extends StatefulWidget {
  final String text;
  final Object? raw;
  final bool disabled;
  final String label;

  /// Retry the last turn (assistant messages, idle sessions only): the
  /// caller passes null while a turn runs, which hides the action.
  final VoidCallback? onRetry;

  /// Fork the session at this message; present only where a fork makes
  /// sense. The caller passes null while a turn runs or the message is not
  /// forkable, which hides the action.
  final VoidCallback? onFork;

  /// Called when the user picks Inspect.
  final void Function(Object? raw)? onInspect;

  final Widget child;

  const MessageActions({
    super.key,
    required this.text,
    required this.label,
    required this.child,
    this.raw,
    this.disabled = false,
    this.onRetry,
    this.onFork,
    this.onInspect,
  });

  @override
  State<MessageActions> createState() => _MessageActionsState();
}

class _MessageActionsState extends State<MessageActions> {
  Future<void> openMenu(BuildContext context, {Offset? at}) async {
    if (widget.disabled) return;
    // Review #16: no overlay (a sheet transition, teardown) means no menu.
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    // Anchor for callers without a position (the overflow button passes its
    // own): the top left of this widget, in global coordinates.
    final box = context.findRenderObject() as RenderBox?;
    final anchor = at ?? box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        anchor & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (widget.onFork != null)
          const PopupMenuItem<String>(
            value: 'fork',
            child: Text('Fork from here'),
          ),
        PopupMenuItem<String>(
          value: 'copy',
          enabled: widget.text.isNotEmpty,
          child: const Text('Copy'),
        ),
        PopupMenuItem<String>(
          value: 'inspect',
          enabled: widget.onInspect != null,
          child: const Text('Inspect'),
        ),
        if (widget.onRetry != null)
          const PopupMenuItem<String>(
            value: 'retry',
            child: Text('Retry turn'),
          ),
        const PopupMenuItem<String>(
          value: 'select',
          child: Text('Select text'),
        ),
      ],
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'fork') {
      widget.onFork?.call();
    } else if (choice == 'copy') {
      Clipboard.setData(ClipboardData(text: widget.text));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
      );
    } else if (choice == 'inspect') {
      widget.onInspect?.call(widget.raw);
    } else if (choice == 'retry') {
      widget.onRetry?.call();
    } else if (choice == 'select') {
      await _showSelectTextSheet(context);
    }
  }

  /// The full message in a SelectableText, for selecting a portion without
  /// the long-press gesture race the SelectionArea under the bubble caused.
  Future<void> _showSelectTextSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              widget.text,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      onLongPressHint: 'Message actions',
      onLongPress: widget.disabled ? null : () => openMenu(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // Center, not stretch: short bubbles must keep hugging their
        // content (the overflow button aligns itself to the right).
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Long-press anywhere on the bubble opens the menu (with haptics);
          // opaque so the padding of an empty or short bubble counts too.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: widget.disabled
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    openMenu(context);
                  },
            child: widget.child,
          ),
          // The explicit no-select affordance: same menu, no selection.
          if (!widget.disabled)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Message actions',
                // Not a token: MessageActions also renders in plain
                // contexts (tests, sheets) whose theme has no OmpTokens.
                icon: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: OmpItemStyle.hit,
                  minHeight: OmpItemStyle.hit,
                ),
                onPressed: () => openMenu(context),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small shared style helpers for item widgets.
class OmpItemStyle {
  const OmpItemStyle._();

  /// 48dp minimum hit target.
  static const double hit = 48;
}
