// The open session screen, ported from web/src/components/SessionView.svelte
// + SessionHeader.svelte + Transcript.svelte.
//
// HARD RULE (RikkaHub bug #1077): the transcript is a reversed ListView, so
// offset 0 IS the newest activity. The session always opens there and can
// never end up stuck at the top; scrolling up to read is respected and a
// jump pill offers the way back down.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../native/keepalive.dart';
import '../../native/method_channel_bridge.dart';
import '../../state/session_controller.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import '../../transcript/items.dart';
import 'approval_panel.dart';
import 'composer.dart';
import 'plan_panel.dart';
import 'plan_ribbon.dart';
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
  late final KeepaliveCoordinator _keepalive;
  ProviderSubscription<SessionState>? _stateSub;

  // Set in initState: dispose still needs the store after `ref` is unsafe.
  // (The session controller is deliberately NOT cached here: invalidation on
  // retry replaces the notifier, so it is read at call time instead.)
  SessionsStore? _sessions;

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(sessionsStoreProvider.notifier);
    _keepalive = KeepaliveCoordinator(
      surface: const MethodChannelKeepaliveSurface(),
      onPause: () => _readController()?.pause(),
      onStopTurn: () async {
        await _readController()?.abort();
      },
      onAnswer: (requestId, answer) async {
        final c = _readController();
        if (c == null) return;
        await c.answerUi(requestId, answer.toMap());
        c.dropUi(requestId);
      },
    );
    KeepaliveRegistry.attach(widget.gwId, _keepalive);
    _lifecycle = AppLifecycleListener(
      // Task F: backgrounding while the open session is running starts the
      // foreground service and keeps the socket; otherwise the controller
      // pauses as before. The sessions LIST polling is owned by
      // SessionsScreen alone — resuming here must not restart it, this
      // screen gets its updates over the WebSocket.
      onResume: () {
        _keepalive.appForegrounded();
        _readController()?.resume();
      },
      onPause: () {
        _keepalive.appBackgrounded();
      },
    );
    // State changes drive the service while backgrounded (turn ended, new
    // blocking dialog). listenManual fires even when no frame is scheduled.
    _stateSub = ref.listenManual<SessionState>(
      sessionControllerProvider(widget.gwId),
      (prev, next) => _keepalive.update(_keepaliveSnapshot(next)),
      fireImmediately: true,
    );
  }

  KeepaliveSnapshot _keepaliveSnapshot(SessionState s) => KeepaliveSnapshot(
        gwId: s.gwId,
        sessionTitle: s.info?.title ?? s.gwId,
        running: s.running,
        tool: s.activity?.toolName,
        turnStartedAt: s.activity?.turnStartedAt,
        pendingUi: s.pendingUi,
      );

  /// The notifier, read at call time: a retry invalidates the provider and
  /// replaces the controller instance.
  SessionController? _readController() {
    if (!mounted) return null;
    return ref.read(sessionControllerProvider(widget.gwId).notifier);
  }

  @override
  void dispose() {
    _stateSub?.close();
    _lifecycle?.dispose();
    KeepaliveRegistry.detach(widget.gwId);
    _keepalive.dispose();
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
            // The plan ribbon sits under the header while the session has
            // todo phases; tapping opens the plan sheet.
            if (state.phase == SessionPhase.ready && state.planPhases.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OmpMetrics.s3, OmpMetrics.s2, OmpMetrics.s3, 0,
                ),
                child: PlanRibbon(
                  phases: state.planPhases,
                  onOpen: () => showPlanSheet(
                    context,
                    phases: state.planPhases,
                    runningTools: [
                      for (final it in state.transcript.items)
                        if (it is ToolItem && it.status == 'running') it,
                    ],
                  ),
                ),
              ),
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
