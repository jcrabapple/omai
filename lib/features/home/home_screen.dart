// Placeholder home: proves the client end to end by listing live and saved
// session titles. The real grouped list lands in Task D1.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../app/app.dart';
import '../../state/connection_notifier.dart';
import '../../theme/tokens.dart';

/// Loads the sessions list using the active connection's token.
final sessionsListProvider =
    FutureProvider.autoDispose<SessionsList>((ref) async {
  final connection = ref.watch(connectionNotifierProvider);
  final active = connection.active;
  if (active == null) throw const Offline('Not signed in.');
  final token = await ref.read(tokenStoreProvider).read(active.id);
  if (token == null) throw const AuthError();
  final make = ref.read(gatewayClientFactoryProvider);
  return make(active.url, token).sessions();
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _signOut(WidgetRef ref) async {
    await ref.read(connectionNotifierProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final sessions = ref.watch(sessionsListProvider);

    return OmpPage(
      title: 'Sessions',
      actions: [
        IconButton(
          tooltip: 'Sign out',
          onPressed: () => _signOut(ref),
          icon: const Icon(Icons.logout),
        ),
      ],
      child: RefreshIndicator(
        color: tokens.accent,
        backgroundColor: tokens.surface,
        onRefresh: () => ref.refresh(sessionsListProvider.future),
        child: sessions.when(
          loading: () => ListView(
            children: [
              const SizedBox(height: 80),
              Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: tokens.accent),
                ),
              ),
            ],
          ),
          error: (error, _) => _ErrorView(error: error),
          data: (list) => _SessionListView(list: list),
        ),
      ),
    );
  }
}

class _SessionListView extends StatelessWidget {
  const _SessionListView({required this.list});

  final SessionsList list;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final rows = [
      for (final s in list.live) (title: s.title, live: true),
      for (final s in list.saved) (title: s.title, live: false),
    ];
    if (rows.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(OmpMetrics.s5),
        children: [
          Text('No sessions yet.',
              style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsBase)),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(OmpMetrics.s4),
      itemCount: rows.length,
      separatorBuilder: (_, _) => SizedBox(height: OmpMetrics.s2),
      itemBuilder: (context, i) {
        final row = rows[i];
        return Container(
          padding: const EdgeInsets.symmetric(
              horizontal: OmpMetrics.s4, vertical: OmpMetrics.s3),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
            border: Border.all(color: tokens.line),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: row.live ? tokens.ok : tokens.ink3,
                ),
              ),
              const SizedBox(width: OmpMetrics.s3),
              Expanded(
                child: Text(
                  row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.ink, fontSize: OmpMetrics.fsBase),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final message = switch (error) {
      AuthError() => 'The gateway rejected the token. Sign in again.',
      LockedOut() => 'Locked out after failed attempts. Wait and retry.',
      EdgeRefused() => 'The edge refused the request. Check the gateway URL.',
      Offline() => 'Could not reach the gateway. Pull to retry.',
      GatewayError e => 'The gateway answered with an error: ${e.message}',
      _ => 'Something went wrong. Pull to retry.',
    };
    return ListView(
      padding: const EdgeInsets.all(OmpMetrics.s5),
      children: [
        Text(message, style: TextStyle(color: tokens.err, fontSize: OmpMetrics.fsBase)),
      ],
    );
  }
}
