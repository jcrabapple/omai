// Diagnostics page: the checks from lib/features/settings/diagnostics.dart,
// one row each, run on open and re-runnable with Run again. Rows run
// concurrently and each updates independently: a slow model-catalog check
// never blocks the others. Pass is a check mark, fail a cross plus the fix
// hint, unknown a question mark plus why it could not run. The catalog row
// shows a small progress indicator while it waits.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../state/connection_notifier.dart';
import '../../theme/tokens.dart';
import 'diagnostics.dart';

/// One row's current state, by check id.
class DiagnosticsState {
  const DiagnosticsState({this.results = const {}, this.running = const {}});
  final Map<String, CheckResult> results;
  final Set<String> running;

  DiagnosticsState copyWith({
    Map<String, CheckResult>? results,
    Set<String>? running,
  }) =>
      DiagnosticsState(
        results: results ?? this.results,
        running: running ?? this.running,
      );
}

/// Seam so tests inject fakes without a GatewayClient.
typedef DiagnosticsFactory = Future<Diagnostics> Function(Ref ref);

/// Builds the real checks from the active connection's client. The token
/// read is async, so the factory is.
Future<Diagnostics> defaultDiagnosticsFactory(Ref ref) async {
  final active = ref.read(connectionNotifierProvider).active;
  if (active == null) {
    return _signedOutDiagnostics();
  }
  final token = await ref.read(tokenStoreProvider).read(active.id);
  if (token == null || token.isEmpty) return _signedOutDiagnostics();
  final client = ref.read(gatewayClientFactoryProvider)(active.url, token);
  return Diagnostics(
    gatewayReachable: client.healthz,
    signedIn: () async {
      try {
        return await client.me();
      } on GatewayClientError {
        rethrow;
      }
    },
    liveSessionIds: () async {
      final list = await client.sessions(limit: 1, includeSaved: false);
      return [for (final s in list.live) s.gwId];
    },
    wsProbe: (gwId) async {
      // The gwId came from liveSessionIds above; no second listing (#8).
      final probe = ref.read(wsProbeProvider);
      return probe(
        client.wsUrl('/omp-ws/$gwId'),
        {'Authorization': 'Bearer $token'},
      );
    },
    system: client.system,
    modelCatalog: () async =>
        (await client.catalogModels()).models.isNotEmpty,
  );
}

Diagnostics _signedOutDiagnostics() => Diagnostics(
  gatewayReachable: () async => throw const Offline('Signed out.'),
  signedIn: () async => throw const Offline('Signed out.'),
  liveSessionIds: () async => [],
  wsProbe: (gwId) async => false,
  system: () async => throw const Offline('Signed out.'),
  modelCatalog: () async => throw const Offline('Signed out.'),
);

final diagnosticsFactoryProvider =
    Provider<DiagnosticsFactory>((ref) => defaultDiagnosticsFactory);

/// Holds the per-row state. autoDispose (triage #7): results belong to an
/// open page, and leaving the page discards them so the next open re-runs.
class DiagnosticsController extends Notifier<DiagnosticsState> {
  int _generation = 0;

  @override
  DiagnosticsState build() {
    // Watching the active connection id: a connection change rebuilds this
    // notifier and re-runs the checks for the new connection (#7).
    ref.watch(connectionNotifierProvider.select((c) => c.active?.id));
    _generation++;
    runAll();
    return const DiagnosticsState();
  }

  Future<void> runAll() async {
    final gen = ++_generation;
    final diagnostics = await ref.read(diagnosticsFactoryProvider)(ref);
    final checks = diagnostics.checks;
    if (!ref.mounted) return;
    state = DiagnosticsState(
      results: state.results,
      running: {for (final c in checks) c.id},
    );
    // Concurrent: each row resolves on its own.
    await Future.wait([
      for (final check in checks)
        () async {
          CheckResult result;
          try {
            result = await check.run();
          } catch (_) {
            result = const CheckResult(CheckStatus.fail, hint: 'The check itself failed.');
          }
          if (gen != _generation || !ref.mounted) return;
          state = state.copyWith(
            results: {...state.results, check.id: result},
            running: {...state.running}..remove(check.id),
          );
        }(),
    ]);
  }

  /// Each row spins until its own new result lands; nothing else resets.
  void runAgain() => runAll();
}

final diagnosticsControllerProvider =
    NotifierProvider.autoDispose<DiagnosticsController, DiagnosticsState>(
  DiagnosticsController.new,
);

class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = ref.watch(diagnosticsControllerProvider);
    final labels = const {
      'gateway': 'Gateway reachable',
      'auth': 'Signed in',
      'websocket': 'WebSocket',
      'omp': 'omp',
      'catalog': 'Model catalog',
    };

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Diagnostics'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        actions: [
          TextButton(
            key: const ValueKey('diagnostics-run-again'),
            onPressed: () =>
                ref.read(diagnosticsControllerProvider.notifier).runAgain(),
            child: Text('Run again', style: TextStyle(color: tokens.accent)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OmpMetrics.s4,
                OmpMetrics.s4,
                OmpMetrics.s4,
                0,
              ),
              child: Text(
                'Checks that the gateway path works end to end.',
                style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
              ),
            ),
            for (final entry in labels.entries)
              _Row(
                id: entry.key,
                label: entry.value,
                state: state,
              ),
            const SizedBox(height: OmpMetrics.s6),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.id, required this.label, required this.state});

  final String id;
  final String label;
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final running = state.running.contains(id);
    final result = state.results[id];

    final (icon, color) = running
        ? (null, tokens.ink3)
        : switch (result?.status) {
            CheckStatus.pass => (Icons.check_circle_outline, tokens.ok),
            CheckStatus.fail => (Icons.cancel_outlined, tokens.err),
            CheckStatus.unknown => (Icons.help_outline, tokens.ink3),
            null => (Icons.help_outline, tokens.ink3),
          };

    return Padding(
      key: ValueKey('diagnostics-row-$id'),
      padding: const EdgeInsets.symmetric(
        horizontal: OmpMetrics.s4,
        vertical: OmpMetrics.s2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: running
                ? const Padding(
                    padding: EdgeInsets.all(OmpMetrics.s2),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: OmpMetrics.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: tokens.ink,
                    fontSize: OmpMetrics.fsBase,
                  ),
                ),
                if (!running && result?.hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: OmpMetrics.s1),
                    child: Text(
                      result!.hint!,
                      style: TextStyle(
                        color: result.status == CheckStatus.fail
                            ? tokens.err
                            : tokens.ink3,
                        fontSize: OmpMetrics.fsSm,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
