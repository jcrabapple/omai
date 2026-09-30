// The composer, ported from web/src/components/Composer.svelte (text parts
// plus the image parts: attach, keyboard insertion, tray, images-only send,
// restore on failure). Auto-grow multiline field (Enter inserts a newline on
// touch), send button; while the turn runs a split action Steer / Queue /
// Stop. Durable send: the text and the tray stay until the gateway acks; on
// failure the failed bubble offers Retry.
//
// While a blocking dialog is open the approval panel replaces this widget
// entirely (see approval_panel.dart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../composer/drafts.dart';
import '../../composer/images.dart';
import '../../composer/slash.dart';
import '../../state/connection_notifier.dart';
import '../../state/session_controller.dart';
import '../../theme/tokens.dart';
import '../../transcript/reducer.dart'
    show LocalRetryInput, lastTurnFailure, reduce;
import '../../transcript/send.dart' show sendPlan, PromptMode;
import 'image_tray.dart';
import 'slash_menu.dart';

/// The composer grows with its text up to this many lines, then scrolls.
const composerMaxLines = 5;

/// Where the attach sheet can pull images from.
enum ImagePickSource { gallery, camera }

/// Decoded picks: bytes plus the source's claimed mime (may be null).
typedef PickedImages = List<(Uint8List, String?)>;

/// Injectable seam for the platform picker, so widget tests never touch the
/// plugin channel.
typedef PickImagesFn = Future<PickedImages> Function(ImagePickSource source);
Future<PickedImages> _pickWithPlugin(ImagePickSource source) async {
  final picker = ImagePicker();
  // Downscale so a phone photo lands well under the 5 MB decoded limit.
  if (source == ImagePickSource.camera) {
    final file = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (file == null) return const [];
    return [(await file.readAsBytes(), file.mimeType)];
  }
  final files = await picker.pickMultiImage(
    maxWidth: 2048,
    maxHeight: 2048,
    imageQuality: 85,
  );
  final out = <(Uint8List, String?)>[];
  for (final file in files) {
    out.add((await file.readAsBytes(), file.mimeType));
  }
  return out;
}

PickImagesFn pickImagesForComposer = _pickWithPlugin;

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

  /// The backend retry (POST /retry) is in flight: the chip shows progress
  /// and cannot be tapped twice.
  bool _retryingTurn = false;

  // Attached images (E2b): tray contents, id source, and the current
  // validation problem shown inline under the tray.
  final List<AttachedImage> _images = [];
  int _nextImageId = 1;
  String? _imageProblem;

  // Slash menu state.
  String? _dismissedFor;
  int _sel = 0;
  Timer? _saveTimer;

  // The failed send the composer is holding restored content for: when its
  // Retry acks and the content is unchanged, it is cleared (triage #12).
  _FailedSendSnapshot? _failedSend;

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

  // ------------------------------------------------------------- images

  Future<void> _addImageBytes(PickedImages picks) async {
    String? problem;
    final added = <AttachedImage>[];
    for (final (bytes, declared) in picks) {
      problem = imageProblem(
        bytes,
        attached: _images.length + added.length,
        declaredMime: declared,
      );
      if (problem != null) break;
      added.add(
        AttachedImage(
          id: _nextImageId++,
          bytes: bytes,
          mimeType: sniffImageMime(bytes)!,
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _images.addAll(added);
      // Any change clears the previous problem; a new one replaces it.
      _imageProblem = problem;
    });
  }

  void _removeImage(int id) {
    setState(() {
      _images.removeWhere((i) => i.id == id);
      _imageProblem = null;
    });
  }

  Future<void> _openAttachSheet() async {
    final source = await showModalBottomSheet<ImagePickSource>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo library'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(ImagePickSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(ImagePickSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final picks = await pickImagesForComposer(source);
    await _addImageBytes(picks);
  }

  // ------------------------------------------------------------- sending

  Future<void> _submit([PromptMode? modeOverride, String? overrideText]) async {
    final state = ref.read(sessionControllerProvider(widget.gwId));
    final message = (overrideText ?? _text.text).trim();
    final ended = state.info?.exited == true;
    if (state.phase != SessionPhase.ready || ended) return;
    if (_sending) return;
    // Images-only sends are allowed; a slash command needs its text.
    if (message.isEmpty && _images.isEmpty) return;
    if (overrideText != null && message.isEmpty) return;
    final plan = sendPlan(state.running);
    final mode = modeOverride ?? plan.primary.mode;
    HapticFeedback.lightImpact();
    setState(() => _sending = true);
    final images = [for (final a in _images) toPromptImage(a.bytes)];
    final ok = await ref
        .read(sessionControllerProvider(widget.gwId).notifier)
        .send(message, mode: mode, images: images.isEmpty ? null : images);
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
      // Clear only after the ack; a failure puts the words back (and the
      // tray never left, so it is "restored" for free).
      _text.clear();
      _images.clear();
      _imageProblem = null;
      _dismissedFor = null;
      await _saveDraftNow();
    } else {
      // The failed bubble explains why; the words come back so nothing is
      // lost, and the draft keeps them. Snapshot the content so a later
      // Retry ack can clear exactly what this failed send restored (#12).
      final ctrlState = ref.read(sessionControllerProvider(widget.gwId));
      final failedId = ctrlState.lastFailedSendId;
      _failedSend = failedId == null
          ? null
          : _FailedSendSnapshot(
              localId: failedId,
              text: _text.text,
              images: List.of(_images),
            );
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

  /// Retry the last failed TURN through the gateway (POST /retry, omp's
  /// abort_retry). Only backend turn failures get here (lastTurnFailure); a
  /// client-side failed send keeps its per-bubble Retry. On success the chip
  /// hides optimistically (LocalRetryInput) until omp starts the new turn.
  Future<void> _retryTurn() async {
    if (_retryingTurn) return;
    setState(() => _retryingTurn = true);
    try {
      final env = await ref.read(sessionEnvProvider.future);
      await env.client.retry(widget.gwId);
      final provider = sessionControllerProvider(widget.gwId);
      final s = ref.read(provider);
      // The controller's _dispatch is private; the retry is a pure
      // transcript-state flag, so it is applied here (web: `retried`).
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ref.read(provider.notifier).state = s.copyWith(
        transcript: reduce(s.transcript, const LocalRetryInput()),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('Could not retry')));
      }
    } finally {
      if (mounted) setState(() => _retryingTurn = false);
    }
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    // A Retry ack for the failed send we are holding: clear the restored
    // text and images if the user has not touched them since (#12).
    ref.listen(sessionControllerProvider(widget.gwId), (prev, next) {
      final failed = _failedSend;
      if (failed == null || !next.ackedRetryIds.contains(failed.localId)) {
        return;
      }
      _failedSend = null;
      final unchanged = _text.text == failed.text && _matchesSnapshot(failed);
      if (!unchanged) return;
      setState(() {
        _text.clear();
        _images.clear();
        _imageProblem = null;
        _dismissedFor = null;
      });
      unawaited(_saveDraftNow());
    });
    final state = ref.watch(sessionControllerProvider(widget.gwId));
    final streaming = state.running;
    final ended =
        state.phase == SessionPhase.gone || state.info?.exited == true;
    final enabled = state.phase == SessionPhase.ready && !ended;
    final canSend =
        enabled &&
        !_sending &&
        (_text.text.trim().isNotEmpty || _images.isNotEmpty);
    // Web Composer canRetry: ready, not streaming, not ended, the last turn
    // ended in a BACKEND failure (never a client-side failed send), and no
    // retry is already waiting for omp to pick it up.
    final failure = lastTurnFailure(state.transcript);
    final canRetry =
        enabled &&
        !streaming &&
        !_sending &&
        !_retryingTurn &&
        failure != null &&
        !state.transcript.retried;
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
            // Backend turn failure: a slim Retry chip above the field (web
            // Composer's canRetry chip).
            if (canRetry)
              Padding(
                padding: const EdgeInsets.only(bottom: OmpMetrics.s1),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _retryTurn,
                    icon: _retryingTurn
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: tokens.accent,
                            ),
                          )
                        : Icon(Icons.refresh, size: 16, color: tokens.accent),
                    label: Text(
                      _retryingTurn ? 'Retrying' : 'Retry turn',
                      style: TextStyle(
                        color: tokens.accent,
                        fontSize: OmpMetrics.fsSm,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            // Attached images: a 56dp thumbnail tray with per-thumb remove,
            // and any validation problem inline under it (not a SnackBar).
            if (_images.isNotEmpty) ...[
              ImageTray(images: _images, onRemove: _removeImage),
              if (_imageProblem != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: OmpMetrics.s1),
                    child: Text(
                      _imageProblem!,
                      style: TextStyle(
                        color: tokens.err,
                        fontSize: OmpMetrics.fsSm,
                      ),
                    ),
                  ),
                ),
            ],
            Row(
              // The button stays by the last line as the field grows.
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: enabled && !_sending ? _openAttachSheet : null,
                  tooltip: 'Attach images',
                  icon: Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 22,
                    color: tokens.ink2,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(OmpMetrics.hit, OmpMetrics.hit),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.padded,
                    disabledForegroundColor: tokens.ink3,
                  ),
                ),
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
                      // Gboard / keyboard image insertion (sticker and photo
                      // keyboards): validated like a picked image.
                      contentInsertionConfiguration:
                          ContentInsertionConfiguration(
                            allowedMimeTypes: const [
                              'image/png',
                              'image/jpeg',
                              'image/webp',
                              'image/gif',
                            ],
                            onContentInserted: (content) {
                              final data = content.data;
                              if (data == null) return;
                              unawaited(
                                _addImageBytes([(data, content.mimeType)]),
                              );
                            },
                          ),
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

  /// True when the tray still holds exactly the images the failed send
  /// restored (same ids and bytes, same order).
  bool _matchesSnapshot(_FailedSendSnapshot failed) {
    if (_images.length != failed.images.length) return false;
    for (var i = 0; i < _images.length; i++) {
      if (_images[i].id != failed.images[i].id ||
          _images[i].bytes != failed.images[i].bytes) {
        return false;
      }
    }
    return true;
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

/// The content a failed send restored into the composer, matched against the
/// composer when that send's Retry acks (triage #12).
class _FailedSendSnapshot {
  const _FailedSendSnapshot({
    required this.localId,
    required this.text,
    required this.images,
  });

  final String localId;
  final String text;
  final List<AttachedImage> images;
}
