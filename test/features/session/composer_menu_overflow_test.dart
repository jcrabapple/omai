// Overflow regression: with the keyboard up on a narrow phone the @ and
// slash menus must shrink to the space above the keyboard instead of pushing
// the composer past the bottom (device report: BOTTOM OVERFLOWED BY 22 PIXELS
// on a 384dp-wide screen with the @ menu open).
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

class Gateway {
  Gateway({this.commands = const []});

  final List<Object?> commands;

  http.Client client() => MockClient((req) async {
    if (req.url.path.endsWith('/files')) {
      final entries = [
        for (var i = 0; i < 12; i++)
          {
            'name': 'file$i.dart',
            'path': 'file$i.dart',
            'isDir': false,
            'size': 10,
          },
      ];
      return _json({'entries': entries});
    }
    if (req.url.path.endsWith('/commands')) {
      return _json({
        'data': {
          'commands': [
            for (var i = 0; i < 12; i++)
              {'name': 'cmd$i', 'description': 'Command $i'},
          ],
        },
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
  Future<StreamSocket> factory(Uri url, Map<String, String> headers) async {
    final sock = FakeSocket(url, headers);
    sockets.add(sock);
    return sock;
  }
}

ProviderContainer _container({
  required Gateway gateway,
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
  required Size size,
  required double keyboard,
  required double textScale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  tester.view.padding = FakeViewPadding(bottom: 0);
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

void main() {
  final surfaces = {
    '384x800 (S26 Ultra at 384dp)': const Size(384, 800),
    '360x640': const Size(360, 640),
  };
  final scales = {0.9: 'font 0.9', 1.3: 'font 1.3'};

  for (final surface in surfaces.entries) {
    for (final scale in scales.entries) {
      testWidgets(
        '@ menu with the keyboard up fits at ${surface.key}, ${scale.value}',
        (tester) async {
          final container = _container(gateway: Gateway(), hub: SocketHub());
          addTearDown(container.dispose);
          await _pumpReady(
            tester,
            container,
            size: surface.value,
            keyboard: 330,
            textScale: scale.key,
          );

          await tester.enterText(find.byType(TextField).first, 'see @');
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pumpAndSettle();

          expect(find.byType(AtMenu), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: 'no RenderFlex overflow with the keyboard up',
          );
          // The input is still on screen and tappable.
          expect(
            tester.getRect(find.byType(TextField).first).bottom,
            lessThanOrEqualTo(surface.value.height),
          );
          // The last entry can be scrolled into view.
          await tester.scrollUntilVisible(
            find.text('file7.dart'),
            100,
            scrollable: find.byType(Scrollable).last,
          );
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'slash menu with the keyboard up fits at ${surface.key}, ${scale.value}',
        (tester) async {
          final container = _container(gateway: Gateway(), hub: SocketHub());
          addTearDown(container.dispose);
          await _pumpReady(
            tester,
            container,
            size: surface.value,
            keyboard: 330,
            textScale: scale.key,
          );

          await tester.enterText(find.byType(TextField).first, '/c');
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pumpAndSettle();

          expect(find.byType(SlashMenu), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: 'no RenderFlex overflow with the keyboard up',
          );
          expect(
            tester.getRect(find.byType(TextField).first).bottom,
            lessThanOrEqualTo(surface.value.height),
          );
          await tester.scrollUntilVisible(
            find.text('/cmd7'),
            100,
            scrollable: find.byType(Scrollable).last,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
