// Raw JSON of one message or tool call, pretty-printed, selectable and
// copyable. Ported from web/src/components/InspectorSheet.svelte (web's
// circular-value guard is not needed here: items keep JSON-decoded data,
// which cannot contain cycles).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';

/// Opens the raw-JSON sheet for [raw]; null raw shows the empty state.
Future<void> showInspectorSheet(BuildContext context, {Object? raw}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // A scroll-controlled sheet may grow to full height; without this it
    // slides under the status bar (edge-to-edge is on by default).
    useSafeArea: true,
    builder: (sheetContext) => InspectorSheet(raw: raw),
  );
}

class InspectorSheet extends StatelessWidget {
  const InspectorSheet({super.key, this.raw});

  final Object? raw;

  String _pretty(Object? value) {
    if (value == null) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final text = _pretty(raw);
    final lines = text.isEmpty ? 0 : text.split('\n').length;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.all(OmpMetrics.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Raw JSON',
                      style: TextStyle(
                        color: tokens.ink,
                        fontSize: OmpMetrics.fsLg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (text.isNotEmpty) ...[
                    Text(
                      '$lines ${lines == 1 ? 'line' : 'lines'}',
                      style: TextStyle(
                        color: tokens.ink3,
                        fontSize: OmpMetrics.fsSm,
                      ),
                    ),
                    const SizedBox(width: OmpMetrics.s2),
                    Semantics(
                      label: 'Copy JSON',
                      child: TextButton.icon(
                        key: const ValueKey('inspector-copy'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: text));
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            const SnackBar(
                              content: Text('JSON copied'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        icon: Icon(Icons.copy, size: 14, color: tokens.ink2),
                        label: Text(
                          'Copy',
                          style: TextStyle(
                            color: tokens.ink2,
                            fontSize: OmpMetrics.fsSm,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: OmpMetrics.s2),
              if (text.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(OmpMetrics.s3),
                  child: Text(
                    'There is no source to show for this item.',
                    style: TextStyle(
                      color: tokens.ink3,
                      fontSize: OmpMetrics.fsSm,
                    ),
                  ),
                )
              else
                Flexible(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(OmpMetrics.s3),
                    decoration: BoxDecoration(
                      color: tokens.inset,
                      borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
                    ),
                    child: SingleChildScrollView(
                      child: SelectionArea(
                        child: Text(
                          text,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: tokens.ink2,
                            fontSize: OmpMetrics.fsSm,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
