// Diagnostics page widget tests: rows resolve independently with injected
// fakes, the WebSocket row shows unknown (not failed) with no live session,
// a 401 shows the sign-in-again hint, and Run again re-runs. The logic-level
// pass/fail matrix lives in diagnostics_test.dart.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/api/errors.dart';
import 'package:ohmypi/features/settings/diagnostics.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/features/settings/diagnostics_page.dart';

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
    wsProbe: () async {
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
}
