// A run of consecutive tool calls: one collapsible row per call (status glyph,
// name, summary, +/- stat, duration) expanding to the output. Ported from
// web/src/components/items/ToolGroup.svelte.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../format.dart';
import '../../theme/tokens.dart';
import '../../transcript/items.dart';
import 'tool_output.dart';

const Map<ToolStatus, String> _statusLabels = {
  'running': 'Running',
  'done': 'Done',
  'error': 'Failed',
  'interrupted': 'Interrupted',
};

class ToolGroup extends StatefulWidget {
  final List<ToolItem> tools;

  /// Called when the user picks Inspect for a tool.
  final void Function(ToolItem tool)? onInspect;

  /// Test seam: ids that start expanded.
  final Set<String> initiallyOpen;

  const ToolGroup({
    super.key,
    required this.tools,
    this.onInspect,
    this.initiallyOpen = const {},
  });

  @override
  State<ToolGroup> createState() => _ToolGroupState();
}

class _ToolGroupState extends State<ToolGroup> {
  late Set<String> _open;

  @override
  void initState() {
    super.initState();
    _open = {...widget.initiallyOpen};
  }

  String _took(ToolItem t) {
    final s = t.startedAt;
    final e = t.endedAt;
    return s != null && e != null ? duration((e - s).toDouble()) : '';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    return Container(
      decoration: BoxDecoration(
        color: t.canvas,
        borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
        border: Border.all(color: t.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < widget.tools.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: t.line),
            _row(context, widget.tools[i]),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, ToolItem tool) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final open = _open.contains(tool.id);
    final failed = tool.status == 'error';

    final Widget status;
    if (tool.status == 'running') {
      status = const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (failed) {
      status = Icon(Icons.error_outline, size: 15, color: t.err);
    } else if (tool.status == 'interrupted') {
      status = Icon(Icons.stop, size: 13, color: t.ink3);
    } else {
      status = Icon(Icons.check, size: 15, color: t.ink3);
    }

    int adds = 0;
    int dels = 0;
    final files = tool.files;
    if (files != null && !failed) {
      for (final f in files) {
        adds += f.adds;
        dels += f.dels;
      }
    }
    final showStat = files != null && files.isNotEmpty && !failed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: open,
          label:
              '${_statusLabels[tool.status] ?? tool.status}: ${tool.toolName} ${tool.summary}',
          child: InkWell(
            onTap: () => setState(() {
              open ? _open.remove(tool.id) : _open.add(tool.id);
            }),
            child: Container(
              constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
              padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s3),
              child: Row(
                children: [
                  SizedBox(
                      width: 16,
                      child: Center(
                          child: Semantics(label: _statusLabels[tool.status] ?? tool.status,
                              excludeSemantics: true, child: status))),
                  const SizedBox(width: OmpMetrics.s3),
                  Text(
                    tool.toolName,
                    style: textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: failed ? t.err : t.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: OmpMetrics.s3),
                  Expanded(
                    child: Text(
                      tool.summary,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                          color: failed ? t.err : t.ink2),
                    ),
                  ),
                  if (showStat)
                    Semantics(
                      label: '$adds added, $dels removed',
                      excludeSemantics: true,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('+$adds',
                            style:
                                TextStyle(color: t.ok, fontSize: OmpMetrics.fsXs)),
                        const SizedBox(width: 4),
                        Text('-$dels',
                            style:
                                TextStyle(color: t.err, fontSize: OmpMetrics.fsXs)),
                      ]),
                    ),
                  if (_took(tool).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: OmpMetrics.s2),
                      child: Text(
                        _took(tool),
                        style: TextStyle(
                            color: t.ink3, fontSize: OmpMetrics.fsXs),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: OmpMetrics.s2),
                    child: Icon(
                      open ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: t.ink3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(
                left: OmpMetrics.s3, right: OmpMetrics.s3, bottom: OmpMetrics.s3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ToolOutput(
                  text: tool.output,
                  error: failed,
                  files: files,
                ),
                const SizedBox(height: OmpMetrics.s2),
                Row(
                  children: [
                    TextButton(
                      onPressed: tool.output.isEmpty
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: tool.output)),
                      child: const Text('Copy output'),
                    ),
                    const SizedBox(width: OmpMetrics.s1),
                    TextButton(
                      onPressed: tool.raw == null
                          ? null
                          : () => widget.onInspect?.call(tool),
                      child: const Text('Inspect'),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
