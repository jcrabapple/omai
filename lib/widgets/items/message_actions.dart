// Copy and inspect for one message: a long press opens the same two actions a
// mouse gets on hover on the web. Ported from
// web/src/components/items/MessageActions.svelte (long-press path; the hover
// toolbar and bottom sheet are web-only, the raw inspector arrives with the
// inspector feature).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';

/// Wraps one message and offers Copy (of [text]) and Inspect ([raw]) on long
/// press. [onInspect] receives the raw object; without it the action copies
/// nothing and stays enabled only when [raw] is present.
class MessageActions extends StatelessWidget {
  final String text;
  final Object? raw;
  final bool disabled;
  final String label;

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
    this.onLongPress,
    this.onInspect,
  });

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
          enabled: text.isNotEmpty,
          child: const Text('Copy'),
        ),
        PopupMenuItem<String>(
          value: 'inspect',
          enabled: raw != null,
          child: const Text('Inspect'),
        ),
      ],
    ).then((choice) {
      if (choice == null || !context.mounted) return;
      if (choice == 'copy') {
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
        );
      } else if (choice == 'inspect') {
        onInspect?.call(raw);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Anchor for callers without a gesture position (Semantics): the top
    // left of this widget, in global coordinates.
    Offset anchor() {
      final box = context.findRenderObject() as RenderBox?;
      return box?.localToGlobal(Offset.zero) ?? Offset.zero;
    }

    void handle(BuildContext c, [Offset? at]) {
      if (onLongPress != null) {
        onLongPress!(c);
      } else {
        _openMenu(c, at ?? anchor());
      }
    }

    return Semantics(
      label: label,
      onLongPressHint: 'Message actions',
      onLongPress: disabled ? null : () => handle(context),
      child: GestureDetector(
        // onLongPressStart alone: a long press also fires onLongPress, so
        // wiring both would open the menu twice.
        onLongPressStart:
            disabled ? null : (details) => handle(context, details.globalPosition),
        child: child,
      ),
    );
  }
}

/// Small shared style helpers for item widgets, resolved from tokens.
class OmpItemStyle {
  const OmpItemStyle._();

  static const double hit = OmpMetrics.hit;
}
