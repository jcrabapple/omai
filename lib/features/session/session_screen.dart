// The open session screen, ported from web/src/components/SessionView.svelte
// + SessionHeader.svelte + Transcript.svelte.
//
// HARD RULE (RikkaHub bug #1077): the transcript is a reversed ListView, so
// offset 0 IS the newest activity. The session always opens there and can
// never end up stuck at the top; scrolling up to read is respected and a
// jump pill offers the way back down.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session_controller.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import 'approval_panel.dart';
import 'composer.dart';
import 'session_header.dart';
import 'transcript_list.dart';

class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key, required this.gwId});

  final String gwId;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  AppLifecycleListener? _lifecycle;

  // Set in initState: dispose still needs the store after `ref` is unsafe.
  // (The session controller is deliberately NOT cached here: invalidation on
  // retry replaces the notifier, so it is read at call time instead.)
  SessionsStore? _sessions;

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(sessionsStoreProvider.notifier);
    _lifecycle = AppLifecycleListener(
      // Task F adds a foreground service; until then backgrounding drops the
      // socket and the poll. The sessions LIST polling is owned by
      // SessionsScreen alone — resuming here must not restart it, this
      // screen gets its updates over the WebSocket.
      onResume: () {
        _readController()?.resume();
      },
      onPause: () {
        _readController()?.pause();
      },
    );
  }

  /// The notifier, read at call time: a retry invalidates the provider and
  /// replaces the controller instance.
  SessionController? _readController() {
    if (!mounted) return null;
    return ref.read(sessionControllerProvider(widget.gwId).notifier);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    // Popping (or disposing) the screen clears the open-session marker.
    _sessions?.setOpenSession(null);
    super.dispose();
  }

  void _retry() {
    ref.invalidate(sessionControllerProvider(widget.gwId));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = ref.watch(sessionControllerProvider(widget.gwId));

    return Scaffold(
      backgroundColor: tokens.canvas,
      appBar: SessionHeader(
        gwId: widget.gwId,
        hasActivity: state.activity != null,
      ),
      body: switch (state.phase) {
        SessionPhase.gone => _GoneView(
          onBack: () => Navigator.of(context).pop(),
        ),
        SessionPhase.error => _ErrorView(error: state.error, onRetry: _retry),
        _ => Column(
          children: [
            Expanded(child: TranscriptList(state: state)),
            // Blocking dialogs take over the composer slot; non-blocking
            // notify requests never reach pendingUi (the reducer filters).
            if (state.pendingUi.isNotEmpty)
              // Flexible: bounds the panel to the space left above the
              // keyboard (a Column hands non-flex children unbounded height,
              // which is exactly how the old panel overflowed).
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmpMetrics.s3,
                    vertical: OmpMetrics.s2,
                  ),
                  child: ApprovalPanel(
                    gwId: widget.gwId,
                    request: state.pendingUi.first,
                    index: 1,
                    total: state.pendingUi.length,
                  ),
                ),
              )
            else
              SessionComposer(gwId: widget.gwId),
          ],
        ),
      },
    );
  }
}

class _GoneView extends StatelessWidget {
  const _GoneView({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(OmpMetrics.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This session has ended',
              style: TextStyle(
                color: tokens.ink,
                fontSize: OmpMetrics.fsLg,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: OmpMetrics.s2),
            Text(
              'The transcript is saved in History.',
              textAlign: TextAlign.center,
              style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsBase),
            ),
            const SizedBox(height: OmpMetrics.s4),
            OutlinedButton(onPressed: onBack, child: const Text('Back')),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(OmpMetrics.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Could not open this session',
              style: TextStyle(
                color: tokens.ink,
                fontSize: OmpMetrics.fsLg,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (error != null && error!.isNotEmpty) ...[
              const SizedBox(height: OmpMetrics.s2),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tokens.ink2,
                  fontSize: OmpMetrics.fsBase,
                ),
              ),
            ],
            const SizedBox(height: OmpMetrics.s4),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
