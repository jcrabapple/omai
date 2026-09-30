// Skills page stale-response guard: two overlapping loads resolving out of
// order must leave the newer response on screen, never a stale one from a
// previous load or connection.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/features/settings/skills_page.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/theme/presets.dart';

http.Response _json(Object? body) => http.Response(
      jsonEncode({'installed': body}),
      200,
      headers: {'content-type': 'application/json'},
    );

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

class MemoryReviewedKv implements ReviewedKv {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

/// One pending skills response per load, handed out in order per host.
class _HostLoads {
  final _pending = <Completer<List<Map<String, Object?>>>>[];
  Completer<List<Map<String, Object?>>> next() {
    final c = Completer<List<Map<String, Object?>>>();
    _pending.add(c);
    return c;
  }

  Future<List<Map<String, Object?>>> get first => _pending.first.future;
}

void main() {
  testWidgets('a slow older load never overwrites a newer one', (tester) async {
    final oldLoads = _HostLoads();
    final newLoads = _HostLoads();
    http.Client clientFor(String host) => MockClient((req) async {
          if (req.url.path.endsWith('/api/skills')) {
            return _json(await (host == 'old'
                ? oldLoads.next()
                : newLoads.next())
                .future);
          }
          return _json([]);
        });

    final connections = const [
      ConnectionRecord(id: 'c1', url: 'https://old', label: 'Old'),
      ConnectionRecord(id: 'c2', url: 'https://new', label: 'New'),
    ];
    final container = ProviderContainer(overrides: [
      connectionPrefsProvider.overrideWithValue(MemoryPrefs(connections)),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
      sessionsPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
      gatewayClientFactoryProvider.overrideWith(
        (ref) => (baseUrl, token) => GatewayClient(
              baseUrl: baseUrl,
              token: token,
              client: clientFor(baseUrl.contains('old') ? 'old' : 'new'),
            ),
      ),
    ]);
    addTearDown(container.dispose);
    // Do NOT hand-set the connection state initially: the notifier's own
    // async load settles on connections.last (c2, the new host), and the
    // page's listenManual reload fires off that transition, like in the app.
    final notifier = container.read(connectionNotifierProvider.notifier);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: OmpTheme.data(OmpPreset.terminal),
          home: const SkillsPage(),
        ),
      ),
    );

    // The first load (c2, from the notifier settling) resolves fast. Plain
    // pumps only: pumpAndSettle advances the fake clock and would time the
    // pending request out.
    for (var i = 0; i < 10 && newLoads._pending.isEmpty; i++) {
      await tester.pump();
    }
    // Leave the first (c2) load pending: the page only reloads on a
    // connection change while it has no data yet.

    // Connection change c2 -> c1: the page reloads from the old host, and
    // that load hangs.
    notifier.state = ConnectionState(connections: connections);
    await tester.pump();
    notifier.state = ConnectionState(connections: connections, activeId: 'c1');
    for (var i = 0; i < 10 && oldLoads._pending.isEmpty; i++) {
      await tester.pump();
    }

    // Back to c2 while the c1 load is still pending: the newer load
    // resolves fast.
    notifier.state = ConnectionState(connections: connections);
    await tester.pump();
    notifier.state = ConnectionState(connections: connections, activeId: 'c2');
    for (var i = 0; i < 10 && newLoads._pending.length < 2; i++) {
      await tester.pump();
    }
    newLoads._pending.last.complete([
      {'name': 'new-skill', 'description': '', 'symlink': false},
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('new-skill'), findsOneWidget);

    // The slow c1 response finally lands: it must not overwrite.
    oldLoads._pending.single.complete([
      {'name': 'old-skill', 'description': '', 'symlink': false},
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('old-skill'), findsNothing,
        reason: 'a stale response from the previous connection is dropped');
    expect(find.text('new-skill'), findsOneWidget);

    // Settle the still-pending first (c2) response so no timer is left.
    if (!newLoads._pending.first.isCompleted) {
      newLoads._pending.first.complete(const []);
    }
    await tester.pump();
  });
}
