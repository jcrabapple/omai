// ChangesPage tests, ported from
// web/src/components/__tests__/ChangesView.test.ts (unified only; the
// split-mode cases are web desktop and stay there).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/features/session/changes_page.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/session_controller.dart';
import 'package:omai/stream/scheduler.dart';
import 'package:omai/stream/session_stream.dart';
import 'package:omai/theme/presets.dart';

import '../../stream/fakes.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response(
      jsonEncode(body),
      status,
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

class SocketHub {
  final List<FakeSocket> sockets = [];
  Future<StreamSocket> factory(Uri url, Map<String, String> headers) async {
    final sock = FakeSocket(url, headers);
    sockets.add(sock);
    return sock;
  }
}

/// The same edits fixture the web ChangesView test uses.
List<Object?> _editsFixture() {
  final raw = jsonDecode(
    File('test/fixtures/transcript/edits.json').readAsStringSync(),
  );
  final messages = raw is Map ? raw['messages'] : raw;
  return messages is List ? messages.cast<Object?>() : <Object?>[];
}

ProviderContainer _container({
  required List<Object?> messages,
}) {
  final hub = SocketHub();
  final gateway = MockClient((req) async {
    if (req.url.path.endsWith('/messages')) {
      return _json({'messages': messages});
    }
    if (req.url.path.endsWith('/state')) return _json({});
    if (req.url.path.endsWith('/stats')) return _json({'data': {}});
    if (req.url.path.endsWith('/commands')) {
      return _json({'data': {'commands': []}});
    }
    return _json({
      'gwId': 'abc',
      'cwd': '/work/x',
      'isStreaming': false,
      'lastEventSeq': 0,
    });
  });
  final env = SessionEnv(
    client: GatewayClient(baseUrl: 'https://g', token: 'tok', client: gateway),
    baseUrl: 'https://g',
    token: 'tok',
    socketFactory: hub.factory,
    scheduler: const SystemScheduler(),
  );
  final container = ProviderContainer(overrides: [
    connectionPrefsProvider.overrideWithValue(
      MemoryPrefs(const [ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')]),
    ),
    tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
    reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
    sessionEnvProvider.overrideWith((ref) async => env),
  ]);
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
    ],
    activeId: 'c1',
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: const ChangesPage(gwId: 'abc'),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    final s = container.read(sessionControllerProvider('abc'));
    if (s.phase == SessionPhase.ready) break;
  }
  await tester.pump();
}

void main() {
  testWidgets('rolls up every file with counts and a row per path',
      (tester) async {
    final container = _container(messages: _editsFixture());
    await _pump(tester, container);
    // Latest diff per path wins; the fixture has 4 changed files (one is a
    // pseudo-path memory note the collector keeps, like the web rollup).
    expect(find.byKey(const ValueKey('change-src/greeter.py')), findsOneWidget);
    expect(find.byKey(const ValueKey('change-/work/CHANGELOG.md')), findsOneWidget);
    expect(find.textContaining('4 files'), findsOneWidget);
    expect(find.textContaining('4 edits'), findsOneWidget);
  });

  testWidgets('offers an empty state without changes', (tester) async {
    final container = _container(messages: const []);
    await _pump(tester, container);
    expect(find.text('No file changes in this session yet.'), findsOneWidget);
  });

  testWidgets('tapping a file opens its diff', (tester) async {
    final container = _container(messages: _editsFixture());
    await _pump(tester, container);
    await tester.tap(find.byKey(const ValueKey('change-src/greeter.py')));
    await tester.pump();
    await tester.pump();
    expect(find.text('src/greeter.py'), findsWidgets);
    expect(find.textContaining('Hello again'), findsOneWidget);
  });
}
