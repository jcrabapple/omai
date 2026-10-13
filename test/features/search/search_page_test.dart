// Search page widget tests, ported from the web SearchView behaviour:
// 250 ms debounce, role chips re-run immediately with the role param,
// stale-response rejection via the generation counter, live hits opening by
// gwId, saved hits resuming from their file, the Top N of M line, empty
// states and error copy.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/api/models.dart';
import 'package:omai/features/search/search_page.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/sessions_store.dart';
import 'package:omai/theme/presets.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

SessionInfo _liveSession(String gwId, String file) => SessionInfo(
  gwId: gwId,
  cwd: '/home/user/proj',
  approvalMode: 'yolo',
  resumedFrom: null,
  ompSessionId: null,
  ompSessionFile: file,
  ompSessionName: 'proj',
  model: null,
  thinkingLevel: null,
  isStreaming: false,
  idleSec: 0,
  exited: false,
  exitCode: null,
  protocolVersion: null,
  uptimeSec: 0,
  subscribers: 0,
  messageCount: 0,
  contextUsage: null,
  lastEventSeq: 0,
  pendingUi: const [],
);

class FakeSessionsStore extends SessionsStore {
  FakeSessionsStore(this._initial);
  final SessionsState _initial;
  @override
  SessionsState build() => _initial;
}

/// Fake gateway that records path + query. [gate], when set, holds the first
/// /api/search request open until completed (stale-response test).
class FakeSearchGateway {
  FakeSearchGateway(this.routes);
  Map<String, Object?> routes;
  final List<(String path, Map<String, String> query)> requests = [];
  Completer<void>? gate;
  bool _gated = false;

  http.Client client() => MockClient((req) async {
    if (req.url.path == '/api/search') {
      requests.add((req.url.path, req.url.queryParameters));
    }
    final g = gate;
    if (g != null && req.url.path == '/api/search' && !_gated) {
      _gated = true;
      await g.future;
    }
    final route = routes[req.url.path];
    if (route is Function) return _json(route(req.url.queryParameters));
    if (route is int) return _json({'error': 'nope'}, status: route);
    return _json(route);
  });

  ProviderContainer container({List<SessionInfo> live = const []}) =>
      ProviderContainer(
        overrides: [
          connectionPrefsProvider.overrideWithValue(
            _MemoryPrefs(const [
              ConnectionRecord(id: 'c1', url: 'https://gw.test', label: 'Test'),
            ]),
          ),
          tokenStoreProvider.overrideWithValue(_FixedTokens()),
          gatewayClientFactoryProvider.overrideWithValue(
            (url, token) =>
                GatewayClient(baseUrl: url, token: token, client: client()),
          ),
          // Keep the sessions store quiet: no poll requests, fixed live list.
          sessionsStoreProvider.overrideWith(
            () => FakeSessionsStore(SessionsState(live: live, loaded: true)),
          ),
        ],
      );
}

class _FixedTokens implements TokenStore {
  @override
  Future<String?> read(String connectionId) async => 'tok';
  @override
  Future<void> write(String connectionId, String token) async {}
  @override
  Future<void> delete(String connectionId) async {}
}

class _MemoryPrefs implements ConnectionPrefs {
  _MemoryPrefs(this.records);
  final List<ConnectionRecord> records;
  @override
  Future<List<ConnectionRecord>> load() async => records;
  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

Future<void> _pump(
  WidgetTester tester,
  FakeSearchGateway fake, {
  required void Function(String gwId) onOpenLive,
  required Future<void> Function(String file, String? cwd) onResume,
  List<SessionInfo> live = const [],
}) async {
  final container = fake.container(live: live);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: SearchPage(onOpenLive: onOpenLive, onResume: onResume),
      ),
    ),
  );
  // Let the connection notifier finish loading the active connection; its
  // init is future-based, which pumpAndSettle does not wait for.
  for (
    var i = 0;
    i < 50 && container.read(connectionNotifierProvider).active == null;
    i++
  ) {
    await tester.pump();
  }
}

void main() {
  final emptyBody = {
    'total': 0,
    'results': [],
    'indexed': {'files': 2, 'messages': 40},
  };

  group('query behaviour', () {
    testWidgets('debounces rapid typing into one request', (tester) async {
      final fake = FakeSearchGateway({'/api/search': emptyBody});
      await _pump(tester, fake, onOpenLive: (_) {}, onResume: (_, _) async {});
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump(const Duration(milliseconds: 100));
      expect(fake.requests, isEmpty, reason: 'debounce still pending');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(fake.requests, hasLength(1));
      expect(fake.requests.single.$2, {'q': 'ab'});
    });

    testWidgets('empty query clears and shows the hint', (tester) async {
      final fake = FakeSearchGateway({'/api/search': emptyBody});
      await _pump(tester, fake, onOpenLive: (_) {}, onResume: (_, _) async {});
      expect(
        find.text('Type to search. Every word is a prefix match.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(fake.requests, hasLength(1));
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(
        find.text('Type to search. Every word is a prefix match.'),
        findsOneWidget,
      );
      expect(fake.requests, hasLength(1), reason: 'no request for empty');
    });

    testWidgets('role switch re-runs immediately with the role param', (
      tester,
    ) async {
      final fake = FakeSearchGateway({'/api/search': emptyBody});
      await _pump(tester, fake, onOpenLive: (_) {}, onResume: (_, _) async {});
      await tester.enterText(find.byType(TextField), 'foo');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(fake.requests.single.$2, {'q': 'foo'});
      await tester.tap(find.text('You'));
      await tester.pump();
      await tester.pump();
      expect(fake.requests, hasLength(2));
      expect(fake.requests.last.$2, {'q': 'foo', 'role': 'user'});
    });

    testWidgets('a stale response never overwrites a newer one', (
      tester,
    ) async {
      final fake = FakeSearchGateway({
        '/api/search': (Map<String, String> q) => {
          'total': 1,
          'results': [
            {'path': '/x/${q['q']}.jsonl', 'snippet': 'result for ${q['q']}'},
          ],
          'indexed': {'files': 1, 'messages': 9},
        },
      });
      fake.gate = Completer<void>();
      await _pump(tester, fake, onOpenLive: (_) {}, onResume: (_, _) async {});
      // First query is gated in flight.
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(fake.requests, hasLength(1));
      // Second query answers first.
      await tester.enterText(find.byType(TextField), 'second');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(fake.requests, hasLength(2));
      expect(find.textContaining('result for second'), findsOneWidget);
      // The stale first response arrives now and must be ignored.
      fake.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('result for second'), findsOneWidget);
      expect(find.textContaining('result for first'), findsNothing);
    });

    testWidgets('error shows the gateway message', (tester) async {
      final fake = FakeSearchGateway({'/api/search': 500});
      await _pump(tester, fake, onOpenLive: (_) {}, onResume: (_, _) async {});
      await tester.enterText(find.byType(TextField), 'boom');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('nope'), findsOneWidget);
    });

    testWidgets('empty results message uses the last query', (tester) async {
      final fake = FakeSearchGateway({'/api/search': emptyBody});
      await _pump(tester, fake, onOpenLive: (_) {}, onResume: (_, _) async {});
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('No matches for "zzz".'), findsOneWidget);
    });
  });

  group('results rendering', () {
    testWidgets('Top N of M when results are truncated', (tester) async {
      final fake = FakeSearchGateway({
        '/api/search': {
          'total': 5,
          'results': [
            {'path': '/a/s.jsonl', 'snippet': 'alpha'},
            {'path': '/b/s.jsonl', 'snippet': 'beta'},
          ],
          'indexed': {'files': 2, 'messages': 9},
        },
      });
      await _pump(tester, fake, onOpenLive: (_) {}, onResume: (_, _) async {});
      await tester.enterText(find.byType(TextField), 'q');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('Top 2 of 5 matches.'), findsOneWidget);
      expect(
        find.text(
          'Full text across 9 messages in 2 saved sessions. '
          'Thinking and tool output are not searched.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('groups by path with headers, snippets keep sentinels out', (
      tester,
    ) async {
      final mark = '\uE000needle\uE001';
      final fake = FakeSearchGateway({
        '/api/search': {
          'total': 2,
          'results': [
            {
              'path': '/a/s.jsonl',
              'cwd': '/home/user/proj',
              'snippet': 'found the $mark here',
              'role': 'user',
              'ts': '2026-10-12T12:00:00Z',
            },
            {
              'path': '/a/s.jsonl',
              'cwd': '/home/user/proj',
              'snippet': 'second $mark',
              'role': 'assistant',
            },
          ],
        },
      });
      await _pump(tester, fake, onOpenLive: (_) {}, onResume: (_, _) async {});
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      // One header for the shared path (cwd basename fallback).
      expect(find.text('proj'), findsOneWidget);
      expect(find.textContaining('found the needle here'), findsOneWidget);
      expect(find.textContaining('second needle'), findsOneWidget);
      expect(find.text('you'), findsOneWidget);
      expect(find.text('omp'), findsNWidgets(2));
      // Sentinels themselves never render.
      expect(find.textContaining('\uE000'), findsNothing);
    });

    testWidgets('live hit opens by gwId from the hit itself', (tester) async {
      final fake = FakeSearchGateway({
        '/api/search': {
          'total': 1,
          'results': [
            {'path': '/a/s.jsonl', 'snippet': 'hi', 'gwId': 'g1'},
          ],
        },
      });
      final opened = <String>[];
      await _pump(
        tester,
        fake,
        onOpenLive: opened.add,
        onResume: (_, _) async {},
      );
      await tester.enterText(find.byType(TextField), 'q');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      await tester.tap(find.textContaining('hi', findRichText: true));
      expect(opened, ['g1']);
    });

    testWidgets('live hit without gwId uses the matching live session', (
      tester,
    ) async {
      final fake = FakeSearchGateway({
        '/api/search': {
          'total': 1,
          'results': [
            {'path': '/live/s.jsonl', 'snippet': 'hi'},
          ],
        },
      });
      final opened = <String>[];
      await _pump(
        tester,
        fake,
        onOpenLive: opened.add,
        onResume: (_, _) async {},
        live: [_liveSession('g9', '/live/s.jsonl')],
      );
      await tester.enterText(find.byType(TextField), 'q');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('live'), findsOneWidget);
      await tester.tap(find.textContaining('hi', findRichText: true));
      expect(opened, ['g9']);
    });

    testWidgets('saved hit resumes with path and cwd', (tester) async {
      final fake = FakeSearchGateway({
        '/api/search': {
          'total': 1,
          'results': [
            {
              'path': '/old/s.jsonl',
              'cwd': '/home/user/proj',
              'snippet': 'needle',
              'archived': true,
            },
          ],
        },
      });
      final resumed = <(String, String?)>[];
      await _pump(
        tester,
        fake,
        onOpenLive: (_) {},
        onResume: (file, cwd) async => resumed.add((file, cwd)),
      );
      await tester.enterText(find.byType(TextField), 'q');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('archived'), findsOneWidget);
      await tester.tap(find.textContaining('needle', findRichText: true));
      expect(resumed, hasLength(1));
      expect(resumed.single.$1, '/old/s.jsonl');
      expect(resumed.single.$2, '/home/user/proj');
    });

    testWidgets('group header opens the group', (tester) async {
      final fake = FakeSearchGateway({
        '/api/search': {
          'total': 1,
          'results': [
            {'path': '/old/s.jsonl', 'title': 'Sink notes', 'snippet': 'hi'},
          ],
        },
      });
      final resumed = <String>[];
      await _pump(
        tester,
        fake,
        onOpenLive: (_) {},
        onResume: (file, _) async => resumed.add(file),
      );
      await tester.enterText(find.byType(TextField), 'q');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      await tester.tap(find.text('Sink notes'));
      expect(resumed, ['/old/s.jsonl']);
      // An ordinary saved (non-archived, not live) transcript carries no tag.
      expect(find.text('archived'), findsNothing);
      expect(find.text('live'), findsNothing);
    });
  });
}
