// The composer, ported from web/src/components/Composer.svelte (text parts;
// images are TODO(E)). Auto-grow multiline field (Enter inserts a newline on
// touch), send button; while the turn runs a split action Steer / Queue /
// Stop. Durable send: the text stays in the field (and the draft) until the
// gateway acks; on failure the failed bubble offers Retry.
//
// While a blocking dialog is open the approval panel replaces this widget
// entirely (see approval_panel.dart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../composer/drafts.dart';
import '../../composer/slash.dart';
import '../../state/connection_notifier.dart';
import '../../state/session_controller.dart';
import '../../theme/tokens.dart';
import '../../transcript/send.dart' show sendPlan, PromptMode;
import 'slash_menu.dart';

class SessionComposer extends ConsumerStatefulWidget {
  const SessionComposer({super.key, required this.gwId});

  final String gwId;

  @override
  ConsumerState<SessionComposer> createState() => _SessionComposerState();
}

class _SessionComposerState extends ConsumerState<SessionComposer> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _sending = false;
  bool _draftLoaded = false;

  // Slash menu state.
  String? _dismissedFor;
  int _sel = 0;
  Timer? _saveTimer;

  // Captured in initState so dispose can flush without touching ref.
  DraftKv? _kv;
  String _connId = '';

  @override
  void initState() {
    super.initState();
    _kv = ref.read(draftKvProvider);
    _connId = ref.read(connectionNotifierProvider).active?.id ?? '';
    _loadDraft();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Flush the draft on the way out, unless a send is in flight (the send
    // path owns the draft then).
    if (!_sending) {
      _saveDraftNow();
    }
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    final draft = await loadDraft(_kv!, _connId, widget.gwId);
    if (!mounted || _draftLoaded) return;
    _draftLoaded = true;
    if (draft.isNotEmpty && _text.text.isEmpty) {
      _text.text = draft;
      _text.selection =
          TextSelection.collapsed(offset: _text.text.length);
    }
  }

  void _onChanged(String value) {
    _sel = 0;
    // Debounced save, like the web's 250ms timer.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), _saveDraftNow);
    setState(() {});
  }

  Future<void> _saveDraftNow() async {
    final kv = _kv;
    if (kv == null) return;
    await saveDraft(kv, _connId, widget.gwId, _text.text);
  }

  // ------------------------------------------------------------- sending

  Future<void> _submit([PromptMode? modeOverride, String? overrideText]) async {
    final state = ref.read(sessionControllerProvider(widget.gwId));
    final message = (overrideText ?? _text.text).trim();
    final ended = state.info?.exited == true;
    if (state.phase != SessionPhase.ready || ended || message.isEmpty) return;
    if (_sending) return;
    final plan = sendPlan(state.running);
    final mode = modeOverride ?? plan.primary.mode;
    HapticFeedback.lightImpact();
    setState(() => _sending = true);
    // TODO(E): image attachments go through the prompt `images` field.
    final ok = await ref
        .read(sessionControllerProvider(widget.gwId).notifier)
        .send(message, mode: mode);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) {
      // Clear only after the ack; a failure puts the words back.
      _text.clear();
      _dismissedFor = null;
      await _saveDraftNow();
    } else {
      // The failed bubble explains why; the words come back so nothing is
      // lost, and the draft keeps them.
      _dismissedFor = null;
      await _saveDraftNow();
    }
    setState(() {});
  }

  Future<void> _stop() async {
    try {
      await ref.read(sessionControllerProvider(widget.gwId).notifier).abort();
    } catch (_) {
      // The stream reports real trouble; leave the turn running.
    }
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = ref.watch(sessionControllerProvider(widget.gwId));
    final streaming = state.running;
    final ended = state.phase == SessionPhase.gone || state.info?.exited == true;
    final enabled = state.phase == SessionPhase.ready && !ended;
    final canSend = enabled && !_sending && _text.text.trim().isNotEmpty;
    final plan = sendPlan(streaming);

    final query = _dismissedFor == _text.text ? null : slashQuery(_text.text);
    final groups =
        query != null ? filterCommands(state.slashCommands, query) : const <SlashGroup>[];
    final flat = flattenGroups(groups);
    final menuOpen = flat.isNotEmpty;
    final selected = flat.isEmpty
        ? 0
        : _sel < 0
            ? 0
            : (_sel >= flat.length ? flat.length - 1 : _sel);

    return Padding(
      padding: EdgeInsets.only(
          left: OmpMetrics.s3,
          right: OmpMetrics.s3,
          top: OmpMetrics.s2,
          bottom: OmpMetrics.s3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (menuOpen)
            Padding(
              padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
              child: SlashMenu(
                groups: groups,
                active: selected,
                onPick: _pick,
                onHover: (i) => setState(() => _sel = i),
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: tokens.field,
              borderRadius: BorderRadius.circular(OmpMetrics.radiusLg),
              border: Border.all(
                  color: _focus.hasFocus ? tokens.accent : tokens.lineStrong),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: OmpMetrics.s4, vertical: OmpMetrics.s1),
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    enabled: enabled && !_sending,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    onChanged: _onChanged,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: !enabled
                          ? 'This session has ended'
                          : streaming
                              ? 'Steer, or queue a message for after this turn'
                              : 'Message omp',
                      hintStyle:
                          TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsBase),
                    ),
                    style: TextStyle(
                        color: tokens.ink,
                        fontSize: 16 // below the 48px iOS zoom threshold
                        ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      OmpMetrics.s2, 0, OmpMetrics.s2, OmpMetrics.s2),
                  child: Row(
                    children: [
                      // TODO(E): attach images (camera, gallery, paste).
                      const Spacer(),
                      if (state.queued > 0) ...[
                        Text('${state.queued} queued',
                            style: TextStyle(
                                color: tokens.ink3, fontSize: OmpMetrics.fsSm)),
                        const SizedBox(width: OmpMetrics.s2),
                      ],
                      if (streaming) ...[
                        _action(context, tokens, 'Stop', Icons.stop,
                            color: tokens.err, onTap: enabled ? _stop : null),
                        const SizedBox(width: OmpMetrics.s1),
                        if (plan.secondary != null)
                          _action(context, tokens, plan.secondary!.label,
                              Icons.low_priority,
                              onTap: canSend
                                  ? () => _submit(plan.secondary!.mode)
                                  : null),
                        const SizedBox(width: OmpMetrics.s1),
                        _action(context, tokens, plan.primary.label, Icons.send,
                            filled: true, onTap: canSend ? () => _submit() : null),
                      ] else
                        IconButton.filled(
                          onPressed: canSend ? () => _submit() : null,
                          icon: const Icon(Icons.arrow_upward),
                          tooltip: 'Send',
                          constraints: const BoxConstraints(
                              minWidth: OmpMetrics.hit, minHeight: OmpMetrics.hit),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _action(BuildContext context, OmpTokens tokens, String label,
      IconData icon,
      {Color? color, bool filled = false, VoidCallback? onTap}) {
    final bg = filled ? tokens.accent : tokens.press;
    final fg = filled ? tokens.accentInk : (color ?? tokens.ink);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(OmpMetrics.radiusLg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(OmpMetrics.radiusLg),
          child: Container(
            constraints:
                const BoxConstraints(minHeight: OmpMetrics.hit, minWidth: OmpMetrics.hit),
            padding:
                const EdgeInsets.symmetric(horizontal: OmpMetrics.s2),
            child: Icon(icon, size: 20, color: onTap == null ? tokens.ink3 : fg),
          ),
        ),
      ),
    );
  }

  void _pick(SlashMatch match) {
    final cmd = match.command;
    if (!wantsInput(cmd)) {
      unawaited(_submit(null, '/${cmd.name}'));
    } else {
      _text.text = slashText(cmd);
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
      _dismissedFor = null;
      _focus.requestFocus();
      setState(() {});
    }
  }
}
