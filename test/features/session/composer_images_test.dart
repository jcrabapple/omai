// Composer image-attach widget tests (E2b). The platform picker is faked via
// the pickImagesForComposer seam, so no plugin channel runs. Covers: attach
// via the fake picker shows thumbnails, remove works, the 5th image is
// refused with the message, an images-only send posts {message: '',
// images:[...]} with the sniffed mimeType, and a failed send restores the
// tray. Reuses the composer test harness.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/composer/drafts.dart';
import 'package:ohmypi/features/session/composer.dart';
import 'package:ohmypi/features/session/session_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/session_controller.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/stream/scheduler.dart';
import 'package:ohmypi/stream/session_stream.dart';
import 'package:ohmypi/theme/presets.dart';

import '../../stream/fakes.dart';

/// A real 1x1 PNG so Image.memory decodes in tests.
final pngBytes = Uint8List.fromList(base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
));

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

class SocketHub {
  final List<FakeSocket> sockets = [];
  Future<StreamSocket> factory(Uri url, Map<String, String> headers) async {
    final sock = FakeSocket(url, headers);
    sockets.add(sock);
    return sock;
  }
}

class FakeGateway {
  final Map<String, Object?> bodies = {};
  final Set<String> failPaths = {};
  int promptCalls = 0;

  http.Client client() => MockClient((req) async {
        if (req.body.isNotEmpty) {
          final decoded = jsonDecode(req.body);
          if (decoded is Map<String, Object?>) bodies[req.url.path] = decoded;
        }
        if (failPaths.any(req.url.path.endsWith)) {
          return _json({'error': 'nope'}, status: 500);
        }
        if (req.url.path.endsWith('/prompt')) {
          promptCalls++;
          return _json({
            'gwId': 'abc',
            'cwd': '/work/x',
            'isStreaming': false,
            'lastEventSeq': 0,
          });
        }
        if (req.url.path.endsWith('/messages')) {
          return _json({'messages': []});
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
}

ProviderContainer _container({
  required FakeGateway gateway,
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
        (ref) => (baseUrl, token) => GatewayClient(
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

Future<void> _pumpReady(WidgetTester tester, ProviderContainer container) async {
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
  setUp(() {
    // Default to a picker that yields one small PNG per call.
    pickImagesForComposer = (_) async => [(pngBytes, null)];
  });

  Future<void> attachOne(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Attach images'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo library'));
    await tester.pumpAndSettle();
  }

  testWidgets('attach via the fake picker shows thumbnails in the tray', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(gateway: FakeGateway(), hub: SocketHub());
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, container);

    await attachOne(tester);
    await attachOne(tester);
    expect(find.byType(Image), findsNWidgets(2),
        reason: 'two thumbnails in the tray');
    expect(find.bySemanticsLabel('Remove image 1'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove image 2'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('remove works', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(gateway: FakeGateway(), hub: SocketHub());
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, container);

    await attachOne(tester);
    await attachOne(tester);
    await tester.tap(find.bySemanticsLabel('Remove image 1'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a 5th image is refused with the count message', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(gateway: FakeGateway(), hub: SocketHub());
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, container);

    for (var i = 0; i < 4; i++) {
      await attachOne(tester);
    }
    expect(find.text('Up to 4 images per message'), findsNothing);
    await attachOne(tester);
    expect(
      find.text('Up to 4 images per message'),
      findsOneWidget,
      reason: 'the problem shows inline under the tray',
    );
    expect(find.byType(Image), findsNWidgets(4),
        reason: 'the refused image is not added');

    // The next change clears the problem.
    await tester.tap(find.bySemanticsLabel('Remove image 1'));
    await tester.pumpAndSettle();
    expect(find.text('Up to 4 images per message'), findsNothing);
    semantics.dispose();
  });

  testWidgets('images-only send posts message: empty with the sniffed mime',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await attachOne(tester);
    // No text: the send button must still be enabled (images-only send).
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();

    final body = gateway.bodies['/api/sessions/abc/prompt'] as Map;
    expect(body['message'], '');
    final images = body['images'] as List;
    expect(images, hasLength(1));
    expect((images.first as Map)['mimeType'], 'image/png',
        reason: 'the mime is sniffed from the magic bytes');
    expect((images.first as Map)['type'], 'image');
    expect(
      ((images.first as Map)['data'] as String).startsWith('data:'),
      isFalse,
      reason: 'raw base64, no data: prefix',
    );
    // Success clears the tray.
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a failed send restores the tray (durable images)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway()..failPaths.add('/prompt');
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await attachOne(tester);
    await attachOne(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Message omp'),
      'with pictures',
    );
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsNWidgets(2),
        reason: 'the failed send keeps the images attached');
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('retry of a failed images-only send resends the images once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway()..failPaths.add('/prompt');
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await attachOne(tester);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    expect(gateway.promptCalls, 0);

    gateway.failPaths.clear();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(gateway.promptCalls, 1);
    final body = gateway.bodies['/api/sessions/abc/prompt'] as Map;
    expect(body['message'], '');
    final images = body['images'] as List;
    expect(images, hasLength(1));
    expect((images.first as Map)['mimeType'], 'image/png');
  });
}
