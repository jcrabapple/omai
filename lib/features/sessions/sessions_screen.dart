// The grouped sessions screen, ported from web/src/components/Rail.svelte +
// RailRow.svelte (list mode). Sections: Needs you / Ready for review /
// Running / Idle / History by day; empty sections are hidden.
//
// Stale-first: an error never blanks the list. When the store has an error
// and a list, a slim banner offers a retry; only a first-load failure (no
// list yet) shows the error as the body.
//
// Polling lives here: it runs while this screen is on top and the app is
// resumed (RouteAware + AppLifecycleListener), and stops otherwise.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../app/app.dart';
import '../../features/new_session/new_session_sheet.dart';
import '../../format.dart';
import '../../state/connection_notifier.dart';
import '../../state/grouping.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import '../../widgets/status_glyph.dart';
import '../session/session_screen.dart';

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen>
    with RouteAware {
  AppLifecycleListener? _lifecycle;
  bool _appResumed = true;
  bool _routeVisible = false;

  // Set in initState: dispose still needs the store after `ref` is unsafe.
  SessionsStore? _store;

  /// Saved-session files with a resume POST in flight; the row shows a
  /// spinner and ignores further taps until it settles.
  final Set<String> _resuming = {};

  @override
  void initState() {
    super.initState();
    _store = ref.read(sessionsStoreProvider.notifier);
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _appResumed = true;
        _syncPolling();
      },
      onPause: () {
        _appResumed = false;
        _syncPolling();
      },
      onHide: () {
        _appResumed = false;
        _syncPolling();
      },
      onShow: () {
        _appResumed =
            SchedulerBinding.instance.lifecycleState ==
            AppLifecycleState.resumed;
        _syncPolling();
      },
    );
    _routeVisible = true;
    _syncPolling();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ompRouteObserver.subscribe(
      this,
      ModalRoute.of(context) as PageRoute<Object?>,
    );
  }

  @override
  void didPush() {
    _routeVisible = true;
    _syncPolling();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _syncPolling();
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    _syncPolling();
  }

  @override
  void didPop() {
    _routeVisible = false;
    _syncPolling();
  }

  void _syncPolling() {
    if (_routeVisible && _appResumed) {
      _store?.startPolling();
    } else {
      _store?.stopPolling();
    }
  }

  @override
  void dispose() {
    ompRouteObserver.unsubscribe(this);
    _lifecycle?.dispose();
    _store?.stopPolling();
    super.dispose();
  }

  Future<void> _signOut() async {
    await ref.read(connectionNotifierProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final sessions = ref.watch(sessionsStoreProvider);
    final groups = ref.watch(sessionGroupsProvider);

    final empty =
        sessions.loaded &&
        groups.needsYou.isEmpty &&
        groups.review.isEmpty &&
        groups.running.isEmpty &&
        groups.idle.isEmpty &&
        groups.history.isEmpty;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Sessions'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More options',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'signout') _signOut();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: !sessions.loaded
          ? (sessions.error != null
                // First-load failure: a spinner forever is a trap. Show the
                // error as the body with a way out.
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(OmpMetrics.s5),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "Can't reach the gateway.",
                            style: TextStyle(
                              color: tokens.ink,
                              fontSize: OmpMetrics.fsLg,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: OmpMetrics.s2),
                          Text(
                            sessions.error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: tokens.ink2,
                              fontSize: OmpMetrics.fsBase,
                            ),
                          ),
                          const SizedBox(height: OmpMetrics.s4),
                          OutlinedButton(
                            onPressed: () => ref
                                .read(sessionsStoreProvider.notifier)
                                .refresh(),
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: tokens.accent,
                      ),
                    ),
                  ))
          : RefreshIndicator(
              color: tokens.accent,
              backgroundColor: tokens.surface,
              onRefresh: () =>
                  ref.read(sessionsStoreProvider.notifier).refresh(),
              child: _buildBody(context, sessions, groups, empty),
            ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: 'New session',
        onPressed: () =>
            showNewSessionSheet(context, ref, onCreated: _onSessionStarted),
        icon: const Icon(Icons.add),
        label: const Text('New session'),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SessionsState sessions,
    SessionGroups groups,
    bool empty,
  ) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    if (empty) {
      return ListView(
        padding: const EdgeInsets.all(OmpMetrics.s5),
        children: [
          Text(
            'No sessions yet.',
            style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsBase),
          ),
        ],
      );
    }
    final children = <Widget>[];
    void section(String label, List<Widget> rows) {
      if (rows.isEmpty) return;
      children.add(_SectionHeader(label: label, count: rows.length));
      children.addAll(rows);
    }

    Widget liveRow(SessionInfo s, SessionStatus status) => SessionRow(
      key: ValueKey('live:${s.gwId}'),
      title: s.title,
      sub: _liveSub(s),
      status: status,
      badge: s.pendingUi.length,
      onTap: () => _openSession(s.gwId),
    );

    section('Needs you', [
      for (final s in groups.needsYou) liveRow(s, 'needs'),
    ]);
    section('Ready for review', [
      for (final s in groups.review) liveRow(s, 'review'),
    ]);
    section('Running', [for (final s in groups.running) liveRow(s, 'running')]);
    section('Idle', [for (final s in groups.idle) liveRow(s, 'idle')]);
    for (final h in groups.history) {
      section(h.label, [
        for (final s in h.items)
          SessionRow(
            key: ValueKey('saved:${s.file}'),
            title: s.title,
            sub:
                '${basename(s.cwd ?? s.cwdFolder)} · '
                '${relativeTime((s.mtime * 1000).round(), DateTime.now().millisecondsSinceEpoch)}',
            status: null,
            busy: _resuming.contains(s.file),
            onTap: _resuming.contains(s.file) ? null : () => _resume(s),
          ),
      ]);
    }
    if (sessions.error != null) {
      children.add(
        _ErrorBanner(
          message: "Can't reach the gateway. Trying again.",
          onRetry: () => ref.read(sessionsStoreProvider.notifier).refresh(),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(OmpMetrics.s4),
      children: children,
    );
  }

  String _liveSub(SessionInfo s) {
    final model = s.model?.displayName;
    return [
      basename(s.cwd),
      model,
    ].where((p) => p != null && p.isNotEmpty).join(' · ');
  }

  void _openSession(String gwId) {
    ref.read(sessionsStoreProvider.notifier).setOpenSession(gwId);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => SessionScreen(gwId: gwId)));
  }

  /// A session the New session sheet created: surface it in the store and
  /// open it.
  void _onSessionStarted(SessionInfo info) {
    final store = ref.read(sessionsStoreProvider.notifier);
    store.patch(info);
    store.refresh();
    _openSession(info.gwId);
  }

  /// Resume a saved transcript: POST {resumeFrom}. alreadyLive means a live
  /// session has the file open, so we open that one instead of forking a
  /// duplicate; cwdFallback means the transcript's folder is gone and the
  /// gateway started in its default, which the user is told about.
  Future<void> _resume(SavedSession s) async {
    if (_resuming.contains(s.file)) return;
    setState(() => _resuming.add(s.file));
    final store = ref.read(sessionsStoreProvider.notifier);
    try {
      final connection = ref.read(connectionNotifierProvider);
      final active = connection.active;
      if (active == null) throw const Offline('Not signed in.');
      final token = await ref.read(tokenStoreProvider).read(active.id);
      if (!mounted) return;
      if (token == null || token.isEmpty) throw const Offline('Not signed in.');
      final client = ref.read(gatewayClientFactoryProvider)(active.url, token);
      final info = await client.startSession(resumeFrom: s.file);
      if (!mounted) return;
      store.patch(info);
      // Open right away; the listing refresh runs in the background. A
      // refresh failure must not block or error the open (store.refresh
      // reports its own error into the store without throwing).
      unawaited(store.refresh());
      _openSession(info.gwId);
      if (info.cwdFallback) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The folder ${s.displayCwd} no longer exists. '
              'The session started in ${info.cwd} instead.',
            ),
          ),
        );
      }
    } on GatewayClientError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not resume the session')),
        );
      }
    } finally {
      _resuming.remove(s.file);
      if (mounted) setState(() {});
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(
        left: OmpMetrics.s1,
        top: OmpMetrics.s4,
        bottom: OmpMetrics.s1,
      ),
      child: Row(
        children: [
          Semantics(
            header: true,
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                color: tokens.ink3,
                fontSize: OmpMetrics.fsXs,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: OmpMetrics.s2),
          Text(
            '$count',
            style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsXs),
          ),
        ],
      ),
    );
  }
}

/// One rail row: glyph, title, sub line. Minimum 48dp target, labelled for
/// screen readers. A null [onTap] (saved history) keeps the metrics but the
/// row is inert.
class SessionRow extends StatelessWidget {
  const SessionRow({
    super.key,
    required this.title,
    required this.sub,
    this.status,
    this.badge = 0,
    this.busy = false,
    this.onTap,
  });

  final String title;
  final String sub;
  final SessionStatus? status;
  final int badge;

  /// True while a resume POST runs for this row: the glyph column shows a
  /// spinner and [onTap] is expected to be null.
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final s = status;
    return Semantics(
      label:
          '$title. ${s != null ? (statusLabels[s] ?? s) : ''} $sub'
          '${badge > 0 ? ', $badge waiting' : ''}',
      button: onTap != null,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OmpMetrics.s3,
              vertical: OmpMetrics.s2,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  child: Center(
                    child: busy
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.accent,
                            ),
                          )
                        : status != null
                        ? StatusGlyph(status: status!)
                        : const SizedBox(width: 8, height: 8),
                  ),
                ),
                const SizedBox(width: OmpMetrics.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.ink,
                          fontSize: OmpMetrics.fsBase,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsSm,
                        ),
                      ),
                    ],
                  ),
                ),
                if (badge > 1) ...[
                  const SizedBox(width: OmpMetrics.s2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.warnSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$badge',
                      style: TextStyle(
                        color: tokens.warn,
                        fontSize: OmpMetrics.fsXs,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: OmpMetrics.s4),
      child: Material(
        color: tokens.errSoft,
        borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
        child: InkWell(
          onTap: onRetry,
          borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: OmpMetrics.hit,
              minWidth: OmpMetrics.hit,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OmpMetrics.s3,
                vertical: OmpMetrics.s2,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(
                        color: tokens.err,
                        fontSize: OmpMetrics.fsSm,
                      ),
                    ),
                  ),
                  Text(
                    'Retry',
                    style: TextStyle(
                      color: tokens.err,
                      fontSize: OmpMetrics.fsSm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Imported late to avoid a circular import at the top: the app module owns
// the route observer the screen subscribes to.
// (SessionScreenRoute lives in session_screen.dart.)
