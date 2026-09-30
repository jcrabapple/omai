// Copy, inspect and retry for one message. Ported from
// web/src/components/items/MessageActions.svelte (long-press path; the hover
// toolbar and bottom sheet are web-only).
//
// Review #6: the text's SelectionArea owns the long press (the Android
// standard: long-press selects a word and shows the selection toolbar). The
// actions ride inside that toolbar via [MessageActionsScope.selectionMenu],
// and a 48dp overflow button opens the same menu without selecting. There is
// deliberately no raw-pointer long-press timer here: it raced the selection
// recognizer and popped the menu during slow drags.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Menu/toolbar actions for the message that built the scope. Found from a
/// SelectionArea's contextMenuBuilder through the enclosing scope.
class MessageActionsScope extends InheritedWidget {
  const MessageActionsScope({
    super.key,
    required this.text,
    required this.label,
    required this.customItems,
    required super.child,
  });

  final String text;
  final String label;

  /// Inspect / Retry turn as selection-toolbar items. [dismiss] hides the
  /// selection toolbar first so the action opens on a clean screen.
  final List<ContextMenuButtonItem> Function(void Function() dismiss)
  customItems;

  static MessageActionsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MessageActionsScope>();

  /// The SelectionArea context menu: the default selectable items (Copy on a
  /// non-empty selection, Select all) plus this message's own actions.
  Widget selectionMenu(BuildContext context, SelectableRegionState region) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: [
        ...region.contextMenuButtonItems,
        ...customItems(region.hideToolbar),
      ],
    );
  }

  @override
  bool updateShouldNotify(MessageActionsScope oldWidget) =>
      oldWidget.text != text || oldWidget.label != label;
}

/// Wraps one message and offers Copy (of [text]), Inspect ([raw]) and an
/// optional [onRetry] action in the selection toolbar and in the overflow
/// menu opened by the more button.
class MessageActions extends StatefulWidget {
  final String text;
  final Object? raw;
  final bool disabled;
  final String label;

  /// Retry the last turn (assistant messages, idle sessions only): the
  /// caller passes null while a turn runs, which hides the action.
  final VoidCallback? onRetry;

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
    this.onInspect,
  });

  @override
  State<MessageActions> createState() => _MessageActionsState();
}

class _MessageActionsState extends State<MessageActions> {
  /// Inspect / Retry turn for the selection toolbar.
  List<ContextMenuButtonItem> _toolbarItems(void Function() dismiss) => [
    if (widget.onInspect != null)
      ContextMenuButtonItem(
        label: 'Inspect',
        onPressed: () {
          dismiss();
          widget.onInspect?.call(widget.raw);
        },
      ),
    if (widget.onRetry != null)
      ContextMenuButtonItem(
        label: 'Retry turn',
        onPressed: () {
          dismiss();
          widget.onRetry!.call();
        },
      ),
  ];

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
      ],
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'copy') {
      Clipboard.setData(ClipboardData(text: widget.text));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
      );
    } else if (choice == 'inspect') {
      widget.onInspect?.call(widget.raw);
    } else if (choice == 'retry') {
      widget.onRetry?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      onLongPressHint: 'Message actions',
      onLongPress: widget.disabled ? null : () => openMenu(context),
      child: MessageActionsScope(
        text: widget.text,
        label: widget.label,
        customItems: _toolbarItems,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // Center, not stretch: short bubbles must keep hugging their
          // content (the overflow button aligns itself to the right).
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            widget.child,
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
