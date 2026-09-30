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

/// The composer grows with its text up to this many lines, then scrolls.
const composerMaxLines = 5;

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
    // Escape dismisses the slash menu (hardware keyboard), like the web's
    // keydown handler setting `dismissedFor`.
    _focus.onKeyEvent = _handleKey;
    _kv = ref.read(draftKvProvider);
    _connId = ref.read(connectionNotifierProvider).active?.id ?? '';
    _loadDraft();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        slashQuery(_text.text) != null) {
      setState(() => _dismissedFor = _text.text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
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
    if (!mounted) {
      // Unmounted mid-send (user backed out): the draft clear must not depend
      // on this widget being alive. A captured kv/key clears it even here.
      final kv = _kv;
      if (ok && kv != null) {
        unawaited(clearDraft(kv, _connId, widget.gwId));
      }
      return;
    }
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
    final ended =
        state.phase == SessionPhase.gone || state.info?.exited == true;
    final enabled = state.phase == SessionPhase.ready && !ended;
    final canSend = enabled && !_sending && _text.text.trim().isNotEmpty;
    final plan = sendPlan(streaming);

    final query = _dismissedFor == _text.text ? null : slashQuery(_text.text);
    final groups = query != null
        ? filterCommands(state.slashCommands, query)
        : const <SlashGroup>[];
    final flat = flattenGroups(groups);
    final menuOpen = flat.isNotEmpty;
    final selected = flat.isEmpty
        ? 0
        : _sel < 0
        ? 0
        : (_sel >= flat.length ? flat.length - 1 : _sel);

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: OmpMetrics.s3,
          right: OmpMetrics.s3,
          top: OmpMetrics.s2,
          bottom: OmpMetrics.s3,
        ),
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
            // While a turn runs, Stop and Queue sit in a slim strip above the
            // field, so the right of the field only ever holds one compact
            // button (Send, or Steer while running).
            if (streaming)
              Padding(
                padding: const EdgeInsets.only(bottom: OmpMetrics.s1),
                child: Row(
                  children: [
                    if (state.queued > 0)
                      Text(
                        '${state.queued} queued',
                        style: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsSm,
                        ),
                      ),
                    const Spacer(),
                    if (plan.secondary != null)
                      _stripAction(
                        tokens,
                        plan.secondary!.label,
                        Icons.low_priority,
                        onTap: canSend
                            ? () => _submit(plan.secondary!.mode)
                            : null,
                      ),
                    _stripAction(
                      tokens,
                      'Stop',
                      Icons.stop,
                      color: tokens.err,
                      onTap: enabled ? _stop : null,
                    ),
                  ],
                ),
              ),
            Row(
              // The button stays by the last line as the field grows.
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: tokens.field,
                      borderRadius: BorderRadius.circular(OmpMetrics.radiusLg),
                      border: Border.all(
                        color: _focus.hasFocus
                            ? tokens.accent
                            : tokens.lineStrong,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: OmpMetrics.s3,
                      vertical: OmpMetrics.s1,
                    ),
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      enabled: enabled && !_sending,
                      // Grows to five lines, then scrolls inside the field.
                      minLines: 1,
                      maxLines: composerMaxLines,
                      textInputAction: TextInputAction.newline,
                      onChanged: _onChanged,
                      decoration: InputDecoration(
                        // The rounded container around the field draws the one outline
                        // (and the focus colour). The app theme gives every field its own
                        // enabled/focused outline and fill, and `border: none` alone doesn't
                        // override those, which drew a second box inside the first.
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: OmpMetrics.s2 + 2,
                        ),
                        hintText: !enabled
                            ? 'This session has ended'
                            : streaming
                            ? 'Steer, or queue for after this turn'
                            : 'Message omp',
                        hintMaxLines: 1,
                        hintStyle: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsBase,
                        ),
                      ),
                      style: TextStyle(
                        color: tokens.ink,
                        fontSize: 16, // below the 48px iOS zoom threshold
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: OmpMetrics.s1),
                _sendButton(
                  tokens,
                  label: plan.primary.label,
                  icon: streaming ? Icons.send : Icons.arrow_upward,
                  onTap: canSend ? () => _submit() : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The round send button beside the field: a 40dp circle inside a 48dp
  /// touch target (the padded tap target), so it looks compact without
  /// becoming hard to hit.
  Widget _sendButton(
    OmpTokens tokens, {
    required String label,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    return IconButton.filled(
      onPressed: onTap,
      tooltip: label,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        fixedSize: const Size(40, 40),
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.padded,
        backgroundColor: tokens.accent,
        foregroundColor: tokens.accentInk,
        disabledBackgroundColor: tokens.press,
        disabledForegroundColor: tokens.ink3,
      ),
    );
  }

  Widget _stripAction(
    OmpTokens tokens,
    String label,
    IconData icon, {
    Color? color,
    VoidCallback? onTap,
  }) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: OmpMetrics.fsSm)),
      style: TextButton.styleFrom(
        foregroundColor: color ?? tokens.ink2,
        disabledForegroundColor: tokens.ink3,
        minimumSize: const Size(OmpMetrics.hit, OmpMetrics.hit),
        padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s2),
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
