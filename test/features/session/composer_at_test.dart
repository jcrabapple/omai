// @-file mention widget tests, ported from web ComposerAt.test.ts cases that
// apply to the phone composer (no desktop keyboard nav, no bottom sheet
// variant: the popover-style menu follows the slash menu's pattern here).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/composer/drafts.dart';
import 'package:omai/features/session/at_menu.dart';
import 'package:omai/features/session/session_screen.dart';
import 'package:omai/features/session/slash_menu.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/session_controller.dart';
import 'package:omai/state/sessions_store.dart';
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

class MemoryDraftKv implements DraftKv {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
  @override
  Future<void> remove(String key) async => map.remove(key);
}

/// Gateway mock: /files answers per prefix, optionally held on a gate so a
/// response can be made stale.
class AtGateway {
  AtGateway();

  /// Prefixes requested, in order.
  final calls = <String>[];

  /// Body per prefix for 200s; missing prefix answers `{entries: []}`.
  final Map<String, Object?> responses = {};

  /// Status per prefix; non-null wins over [responses].
  final Map<String, int> statuses = {};

  /// Hold a prefix's response until completed.
  final Map<String, Completer<void>> gates = {};

  http.Client client() => MockClient((req) async {
    if (req.url.path.endsWith('/files')) {
      final prefix = req.url.queryParameters['prefix'] ?? '';
      calls.add(prefix);
      final gate = gates[prefix];
      if (gate != null) await gate.future;
      final status = statuses[prefix];
      if (status != null) {
        return _json({'error': 'nope'}, status: status);
      }
      return _json(responses[prefix] ?? const {'entries': []});
    }
    if (req.url.path.endsWith('/commands')) {
      return _json({
        'data': {'commands': []},
      });
    }
    return _json({
      'gwId': 'abc',
      'cwd': '/work/x',
      'isStreaming': false,
      'lastEventSeq': 0,
    });
  });
}

class SocketHub {
  final List<FakeSocket> sockets = [];
  FakeSocket get current => sockets.last;
  Future<StreamSocket> factory(Uri url, Map<String, String> headers) async {
    final sock = FakeSocket(url, headers);
    sockets.add(sock);
    return sock;
  }
}

ProviderContainer _container({
  required AtGateway gateway,
  required SocketHub hub,
}) {
  final env = SessionEnv(
    client: GatewayClient(
      baseUrl: 'https://g',
      token: 'tok',
      client: gateway.client(),
    ),
    baseUrl: 'https://g',
    token: 'tok',
    socketFactory: hub.factory,
    scheduler: const SystemScheduler(),
  );
  final container = ProviderContainer(
    overrides: [
      connectionPrefsProvider.overrideWithValue(
        MemoryPrefs(const [
          ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
        ]),
      ),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      sessionsPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
      reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
      draftKvProvider.overrideWithValue(MemoryDraftKv()),
      gatewayClientFactoryProvider.overrideWith(
        (ref) =>
            (baseUrl, token) => GatewayClient(
              baseUrl: baseUrl,
              token: token,
              client: gateway.client(),
            ),
      ),
      sessionEnvProvider.overrideWith((ref) async => env),
    ],
  );
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
    ],
    activeId: 'c1',
  );
  return container;
}

Future<void> _pumpReady(
  WidgetTester tester,
  ProviderContainer container, {
  Size? size,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size ?? const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: SessionScreen(gwId: 'abc'),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    await tester.pump();
    final state = container.read(sessionControllerProvider('abc'));
    if (state.phase == SessionPhase.ready ||
        state.phase == SessionPhase.gone ||
        state.phase == SessionPhase.error) {
      break;
    }
  }
  await tester.pump();
}

Finder _composerField() => find.byType(TextField).first;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_composerField(), text);
  await tester.pump();
}

/// Past the 150ms debounce.
Future<void> _settleFetch(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

const entries = {
  'entries': [
    {'name': 'src', 'path': 'src', 'isDir': true, 'size': null},
    {'name': 'main.dart', 'path': 'src/main.dart', 'isDir': false, 'size': 120},
    {'name': 'readme.md', 'path': 'readme.md', 'isDir': false, 'size': 9},
  ],
};

void main() {
  testWidgets('typing @ opens the menu, debounces, requests prefix "" and '
      'refines within a directory without refetching', (tester) async {
    final gateway = AtGateway()..responses[''] = entries;
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, 'see @');
    // Debounced: nothing fetched yet.
    expect(gateway.calls, isEmpty);
    expect(find.byType(AtMenu), findsNothing);
    await _settleFetch(tester);

    expect(gateway.calls, [''], reason: 'the empty prefix lists the cwd');
    expect(find.byType(AtMenu), findsOneWidget);
    // Dirs first, then files (rankEntries empty-query order).
    expect(find.text('src/'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('readme.md'), findsOneWidget);

    // Refining in the same directory re-ranks what it already has.
    await _type(tester, 'see @re');
    await _settleFetch(tester);
    expect(gateway.calls, [''], reason: 'no refetch within the same directory');
    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('main.dart'), findsNothing);
  });

  testWidgets('@src/ma requests the directory prefix and filters to ma', (
    tester,
  ) async {
    final gateway = AtGateway()
      ..responses['src'] = {
        'entries': [
          {
            'name': 'main.dart',
            'path': 'src/main.dart',
            'isDir': false,
            'size': 1,
          },
          {
            'name': 'other.dart',
            'path': 'src/other.dart',
            'isDir': false,
            'size': 1,
          },
        ],
      };
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, '@src/ma');
    await _settleFetch(tester);
    // atDirPrefix('src/ma') is 'src'; the gateway normalizes 'src' and 'src/'.
    expect(gateway.calls, ['src']);
    expect(find.text('main.dart'), findsOneWidget);
    expect(
      find.text('other.dart'),
      findsNothing,
      reason: 'filtered client-side by the partial name',
    );
  });

  testWidgets('picking a folder navigates into it and keeps the menu open', (
    tester,
  ) async {
    final gateway = AtGateway()
      ..responses[''] = entries
      ..responses['src'] = {
        'entries': [
          {
            'name': 'main.dart',
            'path': 'src/main.dart',
            'isDir': false,
            'size': 1,
          },
        ],
      };
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, '@');
    await _settleFetch(tester);
    await tester.tap(find.text('src/'));
    await tester.pump();
    await _settleFetch(tester);

    expect(
      tester.widget<TextField>(_composerField()).controller!.text,
      '@src/',
      reason: 'the token became @src/',
    );
    expect(
      find.byType(AtMenu),
      findsOneWidget,
      reason: 'the menu stays open in the new directory',
    );
    expect(gateway.calls, ['', 'src']);
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('picking a file inserts the path at the caret and closes', (
    tester,
  ) async {
    final gateway = AtGateway()
      ..responses['src'] = {
        'entries': [
          {
            'name': 'main.dart',
            'path': 'src/main.dart',
            'isDir': false,
            'size': 1,
          },
        ],
      };
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, 'look @src/ma');
    await _settleFetch(tester);
    await tester.tap(find.text('main.dart'));
    await tester.pump();

    final text = tester.widget<TextField>(_composerField()).controller!.text;
    expect(text, 'look @src/main.dart');
    expect(
      find.byType(AtMenu),
      findsNothing,
      reason: 'the menu closes after a pick',
    );
    // Typing elsewhere does not resurrect it.
    await _type(tester, '$text and more');
    await _settleFetch(tester);
    expect(find.byType(AtMenu), findsNothing);
  });

  testWidgets('a stale slow response never overwrites a newer one', (
    tester,
  ) async {
    final gateway = AtGateway()
      ..responses[''] = entries
      ..responses['src'] = {
        'entries': [
          {
            'name': 'fresh.dart',
            'path': 'src/fresh.dart',
            'isDir': false,
            'size': 1,
          },
        ],
      }
      ..gates[''] = Completer<void>();
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, 'a @');
    await tester.pump(const Duration(milliseconds: 200));
    await _type(tester, 'a @src/');
    await _settleFetch(tester);
    expect(gateway.calls, ['', 'src']);

    // The old cwd response lands late: it must not replace the src listing.
    gateway.gates['']!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('fresh.dart'), findsOneWidget);
    expect(
      find.text('readme.md'),
      findsNothing,
      reason: 'the stale listing was dropped',
    );
  });

  testWidgets('a refused listing is a quiet note, not a crash', (tester) async {
    final gateway = AtGateway()..statuses[''] = 403;
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, 'look @');
    await _settleFetch(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Outside the session folder'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // The composer keeps working: a later directory is fetched normally.
    await _type(tester, 'look @src/');
    await _settleFetch(tester);
    expect(gateway.calls, ['', 'src']);
  });

  testWidgets('a 422 shows the same quiet note', (tester) async {
    final gateway = AtGateway()..statuses[''] = 422;
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, '@');
    await _settleFetch(tester);
    expect(find.text('Outside the session folder'), findsOneWidget);
  });

  testWidgets('an empty listing says No matches', (tester) async {
    final gateway = AtGateway()..responses[''] = const {'entries': []};
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, '@');
    await _settleFetch(tester);
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('the slash menu and the @ menu never show together', (
    tester,
  ) async {
    final gateway = AtGateway()..responses[''] = entries;
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, '@src');
    await _settleFetch(tester);
    expect(find.byType(AtMenu), findsOneWidget);
    expect(
      find.byType(SlashMenu),
      findsNothing,
      reason: 'only one menu may be open',
    );
  });

  testWidgets('360dp at text scale 1.3 has no overflow', (tester) async {
    final gateway = AtGateway()..responses[''] = entries;
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(
      tester,
      container,
      size: const Size(360, 800),
      textScale: 1.3,
    );

    await _type(tester, 'see @');
    await _settleFetch(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(AtMenu), findsOneWidget);
  });
}
