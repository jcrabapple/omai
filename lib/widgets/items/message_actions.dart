// Copy, inspect and retry for one message: a long press opens the same
// actions a mouse gets on hover on the web. Ported from
// web/src/components/items/MessageActions.svelte (long-press path; the hover
// toolbar and bottom sheet are web-only).
import 'dart:async';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';

/// Wraps one message and offers Copy (of [text]), Inspect ([raw]) and an
/// optional [onRetry] action on long press.
class MessageActions extends StatefulWidget {
  final String text;
  final Object? raw;
  final bool disabled;
  final String label;

  /// Retry the last turn (assistant messages, idle sessions only): the
  /// caller passes null while a turn runs, which hides the action.
  final VoidCallback? onRetry;

  /// Test/seam override for the long-press handler (default opens the menu).
  final void Function(BuildContext context)? onLongPress;

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
    this.onLongPress,
    this.onInspect,
  });

  @override
  State<MessageActions> createState() => _MessageActionsState();
}

class _MessageActionsState extends State<MessageActions> {
  // The selectable content inside (SelectionArea) owns the long-press in the
  // gesture arena, so the menu trigger runs on the raw pointer stream
  // instead: hold ~kLongPressTimeout without moving to open the actions
  // menu, whether or not the selection recognizer also wins.
  Timer? _holdTimer;

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _openMenu(BuildContext context, Offset globalPosition) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final position = overlay == null
        ? null
        : RelativeRect.fromRect(
            globalPosition & const Size(1, 1),
            Offset.zero & overlay.size,
          );
    showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          enabled: widget.text.isNotEmpty,
          child: const Text('Copy'),
        ),
        PopupMenuItem<String>(
          value: 'inspect',
          enabled: widget.raw != null,
          child: const Text('Inspect'),
        ),
        if (widget.onRetry != null)
          const PopupMenuItem<String>(
            value: 'retry',
            child: Text('Retry turn'),
          ),
      ],
    ).then((choice) {
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
    });
  }

  void _handle(BuildContext context, [Offset? at]) {
    if (widget.onLongPress != null) {
      widget.onLongPress!(context);
      return;
    }
    // Anchor for callers without a gesture position (Semantics): the top
    // left of this widget, in global coordinates.
    final box = context.findRenderObject() as RenderBox?;
    final anchor = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    _openMenu(context, at ?? anchor);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      onLongPressHint: 'Message actions',
      onLongPress:
          widget.disabled ? null : () => _handle(context),
      child: Listener(
        onPointerDown: widget.disabled
            ? null
            : (event) {
                _holdTimer?.cancel();
                _holdTimer = Timer(kLongPressTimeout, () {
                  _holdTimer = null;
                  _handle(context, event.position);
                });
              },
        onPointerUp: (_) => _holdTimer?.cancel(),
        onPointerCancel: (_) => _holdTimer?.cancel(),
        onPointerMove: widget.disabled
            ? null
            : (event) {
                // A drag is scrolling or selecting, not a hold.
                if (event.delta.distanceSquared > 4) _holdTimer?.cancel();
              },
        child: widget.child,
      ),
    );
  }
}

/// Small shared style helpers for item widgets, resolved from tokens.
class OmpItemStyle {
  const OmpItemStyle._();

  static const double hit = OmpMetrics.hit;
}
