// Approval takeover, ported from web/src/components/ApprovalPanel.svelte +
// lib/composer/approval.ts. Replaces the composer while a blocking dialog is
// open: headline, the exact command in a selectable mono block, one 48dp
// button per option. A 409 drops the dialog silently; other errors are shown
// and the buttons re-enable.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart' show GatewayClientError;
import '../../composer/approval.dart';
import '../../state/session_controller.dart';
import '../../theme/tokens.dart';
import '../../wire/wire.dart' show UiRequest;

class ApprovalPanel extends ConsumerStatefulWidget {
  const ApprovalPanel({
    super.key,
    required this.gwId,
    required this.request,
    this.index = 1,
    this.total = 1,
  });

  final String gwId;
  final UiRequest request;
  final int index;
  final int total;

  @override
  ConsumerState<ApprovalPanel> createState() => _ApprovalPanelState();
}

class _ApprovalPanelState extends ConsumerState<ApprovalPanel> {
  bool _busy = false;
  String? _error;
  final TextEditingController _field = TextEditingController();

  @override
  void initState() {
    super.initState();
    _field.text = editorStart(widget.request);
  }

  @override
  void didUpdateWidget(covariant ApprovalPanel old) {
    super.didUpdateWidget(old);
    // A new request resets the field.
    if (old.request.id != widget.request.id) {
      _field.text = editorStart(widget.request);
      _error = null;
      _busy = false;
    }
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _answer(UiAnswer answer) async {
    if (_busy) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _error = null;
    });
    final controller = ref.read(sessionControllerProvider(widget.gwId).notifier);
    try {
      await controller.answerUi(widget.request.id, answer.toMap());
      // The ui_resolved event removes it through the reducer; dropUi is a
      // belt-and-braces local removal so the takeover cannot stick.
      controller.dropUi(widget.request.id);
    } catch (e) {
      if (!mounted) return;
      final outcome = classifyAnswerError(e);
      if (outcome == 'dropped') {
        controller.dropUi(widget.request.id);
      } else {
        setState(() {
          _busy = false;
          _error =
              e is GatewayClientError ? e.message : 'Could not send your answer';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final head = splitTitle(widget.request.title);
    final req = widget.request;
    final disabled = _busy;

    return Material(
      color: tokens.surface,
      borderRadius: BorderRadius.circular(OmpMetrics.radiusLg),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(OmpMetrics.radiusLg),
          border: Border.all(color: tokens.warn, width: 2),
        ),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            // Bounded height: with the keyboard up there is little room, and
            // an unbounded column overflows (web .panel: max-height 70dvh).
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(OmpMetrics.s4),
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 14, color: tokens.warn),
                    const SizedBox(width: OmpMetrics.s1),
                    Text('Needs you',
                        style: TextStyle(
                            color: tokens.warn,
                            fontSize: OmpMetrics.fsSm,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (widget.total > 1)
                      Text('${widget.index} of ${widget.total}',
                          style: TextStyle(
                              color: tokens.ink3,
                              fontSize: OmpMetrics.fsSm)),
                  ],
                ),
                const SizedBox(height: OmpMetrics.s1),
                Text(
                  head.headline.isEmpty ? 'The agent has a question' : head.headline,
                  style: TextStyle(
                      color: tokens.ink,
                      fontSize: OmpMetrics.fsLg,
                      fontWeight: FontWeight.w600),
                ),
                if (head.detail.isNotEmpty) ...[
                  const SizedBox(height: OmpMetrics.s2),
                  ConstrainedBox(
                    // Long commands scroll inside their own box (web .detail:
                    // max-height 30dvh, overflow auto).
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: OmpMetrics.s3, vertical: OmpMetrics.s2),
                      decoration: BoxDecoration(
                        color: tokens.inset,
                        borderRadius:
                            BorderRadius.circular(OmpMetrics.radiusMd),
                      ),
                      child: SingleChildScrollView(
                        child: SelectionArea(
                          child: Text(head.detail,
                              style: TextStyle(
                                  color: tokens.ink2,
                                  fontSize: OmpMetrics.fsSm,
                                  fontFamily: 'monospace')),
                        ),
                      ),
                    ),
                  ),
                ],
                if ((req.message ?? '').isNotEmpty) ...[
                  const SizedBox(height: OmpMetrics.s2),
                  Text(req.message!,
                      style: TextStyle(
                          color: tokens.ink2, fontSize: OmpMetrics.fsBase)),
                ],
                const SizedBox(height: OmpMetrics.s3),
                _buildBody(context, tokens, req, disabled),
                if (_error != null) ...[
                  const SizedBox(height: OmpMetrics.s2),
                  Text(_error!,
                      style:
                          TextStyle(color: tokens.err, fontSize: OmpMetrics.fsSm)),
                ],
                const SizedBox(height: OmpMetrics.s2),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => _answer(UiAnswer.cancelled),
                  child: Text('Dismiss (cancel this request)',
                      style:
                          TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm)),
                ),
              ],
            ),
          ),
        ),
      ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, OmpTokens tokens, UiRequest req,
      bool disabled) {
    if (req.method == 'confirm') {
      return Row(
        children: [
          Expanded(
            child: _choiceButton(context, tokens, 'Yes', 'approve',
                () => _answer(UiAnswer.confirmed(true)), disabled),
          ),
          const SizedBox(width: OmpMetrics.s2),
          Expanded(
            child: _choiceButton(context, tokens, 'No', 'neutral',
                () => _answer(UiAnswer.confirmed(false)), disabled),
          ),
        ],
      );
    }
    if (req.method == 'input' || req.method == 'editor') {
      final isEditor = req.method == 'editor';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _field,
            maxLines: isEditor ? 6 : 1,
            enabled: !disabled,
            textInputAction:
                isEditor ? TextInputAction.newline : TextInputAction.send,
            onSubmitted: (isEditor || disabled)
                ? null
                : (_) => _answer(UiAnswer.value(_field.text)),
            style: TextStyle(
                color: tokens.ink,
                fontSize: OmpMetrics.fsBase,
                fontFamily: isEditor ? 'monospace' : null),
            decoration: InputDecoration(
              hintText: req.placeholder ?? '',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: OmpMetrics.s2),
          SizedBox(
            height: OmpMetrics.hit,
            child: FilledButton(
              onPressed: disabled
                  ? null
                  : () => _answer(UiAnswer.value(_field.text)),
              child: const Text('Send'),
            ),
          ),
        ],
      );
    }
    // select (and anything else that carries options): one button per option.
    final options = req.options ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
            child: _choiceButton(context, tokens, '${options[i]}',
                optionTone('${options[i]}'), () => _answer(UiAnswer.value('${options[i]}')), disabled),
          ),
      ],
    );
  }

  Widget _choiceButton(BuildContext context, OmpTokens tokens, String label,
      OptionTone tone, VoidCallback onTap, bool disabled) {
    Color bg;
    Color fg;
    switch (tone) {
      case 'approve':
        bg = tokens.ok;
        fg = tokens.canvas;
      case 'deny':
        bg = tokens.err;
        fg = tokens.canvas;
      default:
        bg = tokens.press;
        fg = tokens.ink;
    }
    return ConstrainedBox(
      // Minimum touch target; long labels wrap instead of ellipsizing.
      constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: Color.lerp(bg, tokens.canvas, 0.5),
          padding: const EdgeInsets.symmetric(
              horizontal: OmpMetrics.s3, vertical: OmpMetrics.s2),
        ),
        onPressed: disabled ? null : onTap,
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}
