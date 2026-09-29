// Ported from the sessions store cases in
// web/src/lib/state/__tests__/stores.test.ts, plus the stale-first rule.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/api/models.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/state/grouping.dart';

class MockTokenStore extends Mock implements TokenStore {}

class MemoryPrefs implements ConnectionPrefs {
  MemoryPrefs(this.records);
  final List<ConnectionRecord> records;

  @override
  Future<List<ConnectionRecord>> load() async => records;

  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

class MemoryKv implements ReviewedKv {
  @override
  Future<String?> get(String key) async => null;

  @override
  Future<void> set(String key, String value) async {}
}

class FixedClock {
  FixedClock(this.time);
  DateTime time;
}

http.Response _json(Object? body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, Object?> _infoJson(String gwId) => {
      'gwId': gwId,
      'cwd': '/work',
      'isStreaming': false,
    };

void main() {
  late MockTokenStore tokens;
  late FixedClock clock;
  late List<http.Request> requests;
  late http.Client Function() mockClientFactory;
  late ProviderContainer container;

  setUp(() {
    tokens = MockTokenStore();
    clock = FixedClock(DateTime(2026, 9, 29, 15, 0, 0));
    requests = [];
    mockClientFactory = () => MockClient((req) async {
          requests.add(req);
          return _json({
            'live': [
              _infoJson('gw-a'),
              _infoJson('gw-b'),
            ],
            'saved': const [],
          });
        });
    final record = ConnectionRecord(id: 'c1', url: 'https://g', label: 'G');
    final container0 = container = ProviderContainer(overrides: [
      connectionPrefsProvider.overrideWithValue(MemoryPrefs([record])),
      reviewedKvProvider.overrideWithValue(MemoryKv()),
      sessionsClockProvider.overrideWithValue(() => clock.time),
      sessionsPollIntervalProvider.overrideWithValue(
          const Duration(milliseconds: pollMs)),
      tokenStoreProvider.overrideWithValue(tokens),
      gatewayClientFactoryProvider.overrideWith((ref) =>
          (baseUrl, token) =>
              GatewayClient(baseUrl: baseUrl, token: token, client: mockClientFactory())),
    ]);
    addTearDown(container0.dispose);
    when(() => tokens.read(any())).thenAnswer((_) async => 'tok');
    when(() => tokens.delete(any())).thenAnswer((_) async {});
    when(() => tokens.write(any(), any())).thenAnswer((_) async {});
    // Sign in synchronously: plant the state the way sign-in would.
    container0.read(connectionNotifierProvider.notifier).state =
        ConnectionState(connections: [record], activeId: 'c1');
  });

  test('recomputes the rail groups when setTodoActive changes the Set', () async {
    container.read(sessionsStoreProvider);
    await pumpEventQueue();
    final store = container.read(sessionsStoreProvider.notifier);

    expect(container.read(sessionsStoreProvider).todoActive, isEmpty);
    final before = container.read(sessionsStoreProvider).todoActive;

    store.setTodoActive('gw-a', true);
    final todoActive = container.read(sessionsStoreProvider).todoActive;
    expect(identical(todoActive, before), isFalse);
    expect(container.read(sessionGroupsProvider).running.map((s) => s.gwId),
        ['gw-a']);
    expect(
        container.read(sessionGroupsProvider).idle.map((s) => s.gwId), ['gw-b']);

    store.setTodoActive('gw-a', false);
    expect(container.read(sessionGroupsProvider).running, isEmpty);
    expect(container.read(sessionGroupsProvider).idle.map((s) => s.gwId),
        ['gw-a', 'gw-b']);
  });

  test('drops stale todo entries for background sessions on the poll and keeps the open session',
      () async {
    container.read(sessionsStoreProvider);
    await pumpEventQueue();
    final store = container.read(sessionsStoreProvider.notifier);

    store.setTodoActive('gw-a', true);
    store.setTodoActive('gw-b', true);
    store.setOpenSession('gw-a');

    clock.time = clock.time.add(const Duration(milliseconds: todoFreshMs + 1000));
    await store.refresh();

    final s = container.read(sessionsStoreProvider);
    expect(s.todoActive.contains('gw-a'), isTrue);
    expect(s.todoActive.contains('gw-b'), isFalse);
  });

  test('keeps recently refreshed todo entries across a poll', () async {
    container.read(sessionsStoreProvider);
    await pumpEventQueue();
    final store = container.read(sessionsStoreProvider.notifier);

    store.setTodoActive('gw-b', true);
    await store.refresh();

    expect(container.read(sessionsStoreProvider).todoActive.contains('gw-b'),
        isTrue);
  });

  test('refresh keeps the last list on error and exposes refreshing and error separately',
      () async {
    container.read(sessionsStoreProvider);
    await pumpEventQueue();
    expect(container.read(sessionsStoreProvider).live.length, 2);

    // Next fetch fails; the list must survive.
    mockClientFactory = () => MockClient((req) async =>
        _json({'error': 'gateway down'}, status: 500));
    final store = container.read(sessionsStoreProvider.notifier);
    await store.refresh();

    final s = container.read(sessionsStoreProvider);
    expect(s.live.length, 2, reason: 'an error never blanks the list');
    expect(s.loaded, isTrue);
    expect(s.refreshing, isFalse);
    expect(s.error, isNotNull);
  });

  test('a confirmed 401 signs the user out', () async {
    container.read(sessionsStoreProvider);
    await pumpEventQueue();
    expect(container.read(sessionsStoreProvider).live.length, 2);
    mockClientFactory = () => MockClient(
        (req) async => _json({'error': 'bad token'}, status: 401));
    await container.read(sessionsStoreProvider.notifier).refresh();
    await pumpEventQueue();

    final connection = container.read(connectionNotifierProvider);
    expect(connection.active, isNull);
    expect(connection.connections, isEmpty);
    // The store rebuilt for the signed-out connection and cleared its list.
    final s = container.read(sessionsStoreProvider);
    expect(s.loaded, isFalse);
    expect(s.live, isEmpty);
  });

  test('patch, get and remove maintain the live list', () async {
    container.read(sessionsStoreProvider);
    await pumpEventQueue();
    final store = container.read(sessionsStoreProvider.notifier);

    final patched = makeInfo('gw-c');
    store.patch(patched);
    expect(store.get('gw-c')?.gwId, 'gw-c');
    expect(container.read(sessionsStoreProvider).live.first.gwId, 'gw-c');

    store.remove('gw-c');
    expect(store.get('gw-c'), isNull);
  });
  test('polling survives a connection change and stops on stopPolling',
      () async {
    fakeAsync((async) {
      final c1 = const ConnectionRecord(id: 'c1', url: 'https://g', label: 'G');
      final c2 =
          const ConnectionRecord(id: 'c2', url: 'https://g2', label: 'G2');
      void setActive(String id) =>
          container.read(connectionNotifierProvider.notifier).state =
              ConnectionState(
                  connections: [c1, c2],
                  activeId: id == 'c1' ? 'c1' : 'c2');

      container.read(sessionsStoreProvider);
      // A persistent listener makes Riverpod flush dependent rebuilds on
      // the connection change instead of leaving them lazy.
      final sub = container.listen(sessionsStoreProvider, (_, _) {});
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 5));
      final store = container.read(sessionsStoreProvider.notifier);
      final beforePolling = requests.length;

      store.startPolling();
      async.flushMicrotasks();
      final afterStart = requests.length;
      expect(afterStart, greaterThan(beforePolling));

      async.elapse(const Duration(milliseconds: pollMs * 2));
      expect(requests.length, greaterThanOrEqualTo(afterStart + 2),
          reason: 'the periodic timer refreshes');

      // Switch connections: the timer must be rearmed for the new one.
      final beforeSwitch = requests.length;
      setActive('c2');
      async.elapse(const Duration(milliseconds: 5));
      final afterSwitch = requests.length;
      expect(afterSwitch, greaterThan(beforeSwitch),
          reason: 'the new connection is fetched immediately');
      async.elapse(const Duration(milliseconds: pollMs * 2));
      expect(requests.length, greaterThanOrEqualTo(afterSwitch + 2),
          reason: 'polling continues for the new connection');

      store.stopPolling();
      final afterStop = requests.length;
      async.elapse(const Duration(milliseconds: pollMs * 3));
      expect(requests.length, afterStop,
          reason: 'stopPolling halts the timer');
      sub.close();
    });
  });

  test('sessionGroupsProvider groups history with the injected clock',
      () async {
    // "Now" for the grouping: a date far from the real wall clock, so the
    // test only passes when the injected sessionsClockProvider is used.
    clock.time = DateTime(2027, 9, 29, 15, 0, 0);
    final mtime = clock.time
            .subtract(const Duration(days: 3))
            .millisecondsSinceEpoch /
        1000;
    mockClientFactory = () => MockClient((req) async => _json({
          'live': const [],
          'saved': [
            {
              'file': '/work/omp.json',
              'mtime': mtime,
              'sizeBytes': 10,
              'cwdFolder': 'work',
              'cwd': '/work',
              'title': 'session',
              'running': false,
            }
          ],
        }));
    container.read(sessionsStoreProvider);
    await pumpEventQueue();
    await container.read(sessionsStoreProvider.notifier).refresh();

    final groups = container.read(sessionGroupsProvider);
    expect(groups.history.single.key, HistoryBucketKey.week,
        reason: 'three days before the injected now is the week bucket');
  });
}

// Small helper: build a SessionInfo from a partial json (default-filled).
SessionInfo makeInfo(String gwId) =>
    SessionInfo.fromJson({'gwId': gwId, 'cwd': '/work'});
