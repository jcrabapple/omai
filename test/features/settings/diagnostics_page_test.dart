// Diagnostics page widget tests: rows resolve independently with injected
// fakes, the WebSocket row shows unknown (not failed) with no live session,
// a 401 shows the sign-in-again hint, and Run again re-runs. The logic-level
// pass/fail matrix lives in diagnostics_test.dart.

import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/api/errors.dart';
import 'package:ohmypi/features/settings/diagnostics.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/features/settings/diagnostics_page.dart';

class _FixedTokenStore implements TokenStore {
  @override
  Future<String?> read(String connectionId) async => 'tok';
  @override
  Future<void> write(String connectionId, String token) async {}
  @override
  Future<void> delete(String connectionId) async {}
}

class MemoryPrefs implements ConnectionPrefs {
  MemoryPrefs(this.records);
  final List<ConnectionRecord> records;
  @override
  Future<List<ConnectionRecord>> load() async => records;
  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

Diagnostics fakeDiagnostics({
  Object? me = 'bearer',
  List<String> live = const ['gw-1'],
  Object? ws = true,
  Completer<bool>? slowCatalog,
}) {
  return Diagnostics(
    gatewayReachable: () async => true,
    signedIn: () async {
      if (me is Exception) throw me;
      return me as String;
    },
    liveSessionIds: () async => live,
    wsProbe: (gwId) async {
      if (ws is Future) return await ws;
      return ws == true;
    },
    system: () async => {
      'omp': {'version': '1.0.0'},
    },
    modelCatalog: () async =>
        slowCatalog != null ? slowCatalog.future : true,
  );
}

Future<ProviderContainer> pump(
  WidgetTester tester,
  Diagnostics diagnostics,
) async {
  final container = ProviderContainer(overrides: [
    diagnosticsFactoryProvider.overrideWithValue((ref) async => diagnostics),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: DiagnosticsPage()),
    ),
  );
  return container;
}

void main() {
  testWidgets('all checks pass on a healthy gateway', (tester) async {
    await pump(tester, fakeDiagnostics());
    await tester.pumpAndSettle();
    for (final id in ['gateway', 'auth', 'websocket', 'omp', 'catalog']) {
      expect(
        find.byKey(ValueKey('diagnostics-row-$id')),
        findsOneWidget,
        reason: id,
      );
    }
    // No fix hints when everything passes (labels only).
    expect(find.textContaining('Check the URL'), findsNothing);
    expect(find.textContaining('Sign in again'), findsNothing);
    expect(find.textContaining('WebSockets'), findsNothing);
  });

  testWidgets('no live session: the WebSocket row is unknown, not failed',
      (tester) async {
    await pump(tester, fakeDiagnostics(live: const [], ws: false));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('diagnostics-row-websocket'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.text('Checked once a session is live.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a rejected token shows the sign-in-again hint', (tester) async {
    await pump(tester, fakeDiagnostics(me: const AuthError('401')));
    await tester.pumpAndSettle();
    expect(find.text('The token was rejected. Sign in again.'), findsOneWidget);
  });

  testWidgets('a slow catalog does not block the other rows', (tester) async {
    final slow = Completer<bool>();
    await pump(tester, fakeDiagnostics(slowCatalog: slow));
    await tester.pump(const Duration(milliseconds: 50));
    // The fast rows resolved while the catalog row is still running.
    expect(find.text('The token was rejected. Sign in again.'), findsNothing);
    slow.complete(true);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(5));
  });

  testWidgets('Run again re-runs the checks', (tester) async {
    final container = await pump(tester, fakeDiagnostics());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('diagnostics-run-again')));
    await tester.pumpAndSettle();
    expect(
      container.read(diagnosticsControllerProvider).running,
      isEmpty,
    );
    expect(
      container.read(diagnosticsControllerProvider).results.length,
      5,
    );
  });

  testWidgets('reopening the page runs fresh checks (autoDispose)', (
    tester,
  ) async {
    var builds = 0;
    final container = ProviderContainer(overrides: [
      diagnosticsFactoryProvider.overrideWithValue((ref) async {
        builds++;
        return fakeDiagnostics();
      }),
    ]);
    addTearDown(container.dispose);
    Future<void> open() => tester.tap(find.byKey(const ValueKey('diag-open')));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: OmpTheme.data(OmpPreset.terminal),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('diag-open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DiagnosticsPage()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await open();
    await tester.pumpAndSettle();
    expect(find.byType(DiagnosticsPage), findsOneWidget);
    expect(builds, 1, reason: 'the first open runs the checks');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(DiagnosticsPage), findsNothing);
    await open();
    await tester.pumpAndSettle();
    expect(builds, 2,
        reason: 'the reopened page discards the stale results and reruns');
  });

  testWidgets('a connection change while open re-runs the checks', (
    tester,
  ) async {
    var builds = 0;
    final container = ProviderContainer(overrides: [
      diagnosticsFactoryProvider.overrideWithValue((ref) async {
        builds++;
        return fakeDiagnostics();
      }),
      connectionPrefsProvider.overrideWithValue(MemoryPrefs(const [
        ConnectionRecord(id: 'c1', url: 'https://one', label: 'One'),
        ConnectionRecord(id: 'c2', url: 'https://two', label: 'Two'),
      ])),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      sessionsPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
    ]);
    addTearDown(container.dispose);
    // The notifier's own async load settles on connections.last (c2); let
    // it settle before switching, so the change below is a real c2 -> c1.
    final notifier = container.read(connectionNotifierProvider.notifier);
    container.read(connectionNotifierProvider);
    await tester.pump();
    final settled = container.read(connectionNotifierProvider);
    final initialActive = settled.active?.id;
    final other = initialActive == 'c1' ? 'c2' : 'c1';
    final switched = settled.copyWith(activeId: other);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: OmpTheme.data(OmpPreset.terminal),
          home: const DiagnosticsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(builds, 1);
    notifier.state = switched;
    await tester.pumpAndSettle();
    expect(container.read(connectionNotifierProvider).active?.id, other);
    expect(builds, 2,
        reason: 'a changed connection id reruns the checks');
  });
}
