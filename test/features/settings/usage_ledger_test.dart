// Usage ledger tests: the History section of the Usage page (ported from
// web UsageView.svelte). Covers robust parsing with missing fields, the 404
// "newer gateway" fallback, day-range and model-filter refetches, the
// refetch-error banner that keeps the last good data, stale-response
// rejection, the per-session rollup, and 360dp at 1.3 text scale.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/features/settings/usage_ledger.dart';
import 'package:omai/features/settings/usage_page.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/theme/presets.dart';

import 'fakes.dart' show FixedTokenStore, MemoryPrefs, activeRecord;

http.Response _json(Object? body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Fake gateway that records path + query for every request. Route values:
/// a Map body (status 200), an int status, or null (404). [gate], when set,
/// holds the next /api/ledger request open until completed (stale-response
/// test).
class FakeLedgerGateway {
  FakeLedgerGateway(this.routes);

  Map<String, Object?> routes;
  final List<(String path, Map<String, String> query)> requests = [];
  Completer<void>? gate;
  int _gateHits = 0;

  http.Client client() => MockClient((req) async {
    requests.add((req.url.path, req.url.queryParameters));
    final g = gate;
    if (g != null &&
        req.url.path == '/api/ledger' &&
        _gateHits++ == 0 &&
        !g.isCompleted) {
      await g.future;
    }
    final route = routes[req.url.path];
    if (route == null) return _json({'error': 'not found'}, status: 404);
    if (route is int) return _json({'error': 'nope'}, status: route);
    if (route is Function) return _json(route(req.url.queryParameters));
    return _json(route);
  });

  ProviderContainer get container => ProviderContainer(
    overrides: [
      connectionPrefsProvider.overrideWithValue(
        MemoryPrefs(const [activeRecord]),
      ),
      tokenStoreProvider.overrideWithValue(const FixedTokenStore()),
      gatewayClientFactoryProvider.overrideWithValue(
        (url, token) =>
            GatewayClient(baseUrl: url, token: token, client: client()),
      ),
    ],
  );
}

const ledgerBody = {
  'days': 30,
  'totals': {
    'turns': 5,
    'turnsOk': 4,
    'input': 1200,
    'output': 340,
    'cacheRead': 20000,
    'cacheWrite': 900,
    'cost': 0.42,
  },
  'perDay': [
    {'date': '2026-09-28', 'input': 700, 'output': 200, 'cost': 0.2},
    {'date': '2026-09-29', 'input': 500, 'output': 140, 'cost': 0.22},
  ],
  'perModel': [
    {
      'provider': 'zeta',
      'model': 'zeta-mini',
      'turns': 3,
      'input': 800,
      'output': 200,
      'cacheRead': 12000,
      'cost': 0.3,
    },
    {
      'provider': 'acme',
      'model': 'acme-1',
      'turns': 2,
      'input': 400,
      'output': 140,
      'cacheRead': 8000,
      'cost': 0.12,
    },
  ],
};

const sessionsBody = {
  'days': 30,
  'sessions': [
    {
      'sessionName': 'fix the sink',
      'cwd': '/home/user/proj/app',
      'turns': 4,
      'input': 1000,
      'output': 300,
      'cacheRead': 15000,
      'cost': 0.35,
      'lastTs': 1759200000,
    },
  ],
};

Future<void> pumpPage(WidgetTester tester, FakeLedgerGateway fake) async {
  final container = fake.container;
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: const UsagePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ledger parsing (pure)', () {
    test('missing and odd fields become zeros and empty lists', () {
      final agg = LedgerAgg.fromJson(null);
      expect(agg.days, 30);
      expect(agg.totals.turns, 0);
      expect(agg.totals.cost, 0);
      expect(agg.perDay, isEmpty);
      expect(agg.perModel, isEmpty);
      expect(agg.chartMax, 1);

      final partial = LedgerAgg.fromJson({
        'days': 'ninety',
        'totals': {'turns': 'x', 'cost': null, 'input': 12.5},
        'perDay': [
          null,
          'junk',
          {'date': 7, 'input': 'many'},
        ],
        'perModel': [
          {'model': 'm', 'turns': 2, 'provider': null},
        ],
      });
      expect(partial.days, 30, reason: 'non-int days falls back');
      expect(partial.totals.turns, 0);
      expect(partial.totals.cost, 0);
      expect(partial.totals.input, 12.5);
      expect(partial.perDay.length, 2, reason: 'null entries dropped');
      expect(partial.perDay[0].date, '');
      expect(partial.perDay[0].input, 0);
      expect(partial.perModel.single.model, 'm');
      expect(partial.perModel.single.provider, '');
      expect(partial.perModel.single.key, 'm/');
    });

    test('session label falls back to cwd basename then Unnamed', () {
      expect(
        LedgerSession.fromJson({
          'sessionName': '  ',
          'cwd': '/home/user/proj/app',
        }).label(),
        'app',
      );
      expect(LedgerSession.fromJson({'cwd': null}).label(), 'Unnamed');
      expect(LedgerSession.fromJson({'sessionName': 'named'}).label(), 'named');
    });

    test('full bodies parse with perDay order kept and chartMax set', () {
      final agg = LedgerAgg.fromJson(ledgerBody);
      expect(agg.days, 30);
      expect(agg.perDay.first.date, '2026-09-28');
      expect(agg.perDay.length, 2);
      expect(agg.totals.cost, 0.42);
      expect(agg.chartMax, 900);
      expect(LedgerRollup.fromJson(sessionsBody).sessions.single.turns, 4);
    });
  });

  group('usage history (widget)', () {
    testWidgets('renders totals, chart, model table and session table', (
      tester,
    ) async {
      final fake = FakeLedgerGateway({
        '/api/ledger': ledgerBody,
        '/api/ledger/sessions': sessionsBody,
      });
      await pumpPage(tester, fake);

      expect(find.byKey(const ValueKey('ledger-chart')), findsOneWidget);
      expect(find.text('5 turns in the last 30 days'), findsOneWidget);
      expect(find.text('1.2k'), findsWidgets);
      expect(
        find.byKey(const ValueKey('ledger-model-zeta-mini/zeta')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ledger-session-0')), findsOneWidget);
      expect(find.text('fix the sink'), findsOneWidget);
      // Semantics summary so the chart is not a TalkBack black hole.
      expect(
        find.bySemanticsLabel('Cost over the last 30 days: \$0.42'),
        findsWidgets,
      );
    });

    testWidgets('a 404 ledger shows the newer-gateway copy, not an error', (
      tester,
    ) async {
      final fake = FakeLedgerGateway({
        '/api/ledger': 404,
        '/api/ledger/sessions': sessionsBody,
      });
      await pumpPage(tester, fake);

      expect(find.byKey(const ValueKey('ledger-unsupported')), findsOneWidget);
      expect(find.text('Usage history needs a newer gateway.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ledger-chart')), findsNothing);
    });

    testWidgets('day range switch refetches with days=7 and days=90', (
      tester,
    ) async {
      final fake = FakeLedgerGateway({
        '/api/ledger': ledgerBody,
        '/api/ledger/sessions': sessionsBody,
      });
      await pumpPage(tester, fake);

      await tester.tap(find.byKey(const ValueKey('ledger-range-7')));
      await tester.pumpAndSettle();
      expect(
        fake.requests.any((r) => r.$1 == '/api/ledger' && r.$2['days'] == '7'),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('ledger-range-90')));
      await tester.pumpAndSettle();
      expect(
        fake.requests.any((r) => r.$1 == '/api/ledger' && r.$2['days'] == '90'),
        isTrue,
      );
    });

    testWidgets('model filter refetches with model= and provider=', (
      tester,
    ) async {
      final fake = FakeLedgerGateway({
        '/api/ledger': ledgerBody,
        '/api/ledger/sessions': sessionsBody,
      });
      await pumpPage(tester, fake);

      await tester.tap(find.byKey(const ValueKey('ledger-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('zeta-mini/zeta').last);
      await tester.pumpAndSettle();

      final hit = fake.requests.lastWhere((r) => r.$1 == '/api/ledger');
      expect(hit.$2['model'], 'zeta-mini');
      expect(hit.$2['provider'], 'zeta');
    });

    testWidgets('refetch error keeps the previous data under a banner', (
      tester,
    ) async {
      final fake = FakeLedgerGateway({
        '/api/ledger': ledgerBody,
        '/api/ledger/sessions': sessionsBody,
      });
      await pumpPage(tester, fake);

      fake.routes = {'/api/ledger': 500, '/api/ledger/sessions': 500};
      await tester.tap(find.byKey(const ValueKey('ledger-range-7')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('ledger-refetch-banner')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Could not refresh usage. Showing results from the previous fetch.',
        ),
        findsOneWidget,
      );
      // The last good data is still on screen (still the 30-day totals).
      expect(find.text('5 turns in the last 30 days'), findsOneWidget);
      expect(find.byKey(const ValueKey('ledger-chart')), findsOneWidget);
    });

    testWidgets('a stale response from an older request is ignored', (
      tester,
    ) async {
      final fake = FakeLedgerGateway({
        '/api/ledger': ledgerBody,
        '/api/ledger/sessions': sessionsBody,
      });
      await pumpPage(tester, fake);

      // Pick 7d, hold the /api/ledger answer open, then pick 90d which
      // answers immediately (with the server-keyed 90 in its body). When
      // the held 7d answer finally lands it must not overwrite the newer
      // 90d one.
      fake.routes = {
        '/api/ledger': (Map<String, String> q) => {
          ...ledgerBody,
          'days': int.parse(q['days']!),
        },
        '/api/ledger/sessions': sessionsBody,
      };
      fake.gate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('ledger-range-7')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('ledger-range-90')));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('5 turns in the last 90 days'), findsOneWidget);

      fake.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.text('5 turns in the last 90 days'), findsOneWidget);
      expect(find.text('5 turns in the last 7 days'), findsNothing);
    });

    testWidgets('fits 360dp at 1.3 text scale with no overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final fake = FakeLedgerGateway({
        '/api/ledger': ledgerBody,
        '/api/ledger/sessions': sessionsBody,
      });
      final container = fake.container;
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: MaterialApp(
              theme: OmpTheme.data(OmpPreset.terminal),
              home: const UsagePage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('ledger-chart')), findsOneWidget);
      expect(find.byKey(const ValueKey('ledger-session-0')), findsOneWidget);
    });
  });
}
