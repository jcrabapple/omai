// SessionInfoSheet tests: where/model sections, thinking chips call
// setThinking, model switching calls setModel, and Stats for nerds shows the
// controller's per-turn numbers. Ported from
// web/src/components/__tests__/SessionInfoSheet.test.ts (the queue/protocol
// section is web-only) plus the stats work that arrives with this feature.
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/api/models.dart' show CatalogModel, ModelCost;
import 'package:omai/features/session/session_info_sheet.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/session_controller.dart';
import 'package:omai/state/models_store.dart';
import 'package:omai/stream/scheduler.dart';
import 'package:omai/stream/session_stream.dart';
import 'package:omai/theme/presets.dart';
import 'package:omai/theme/tokens.dart';

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
  FakeSocket get current => sockets.last;
  Future<StreamSocket> factory(Uri url, Map<String, String> headers) async {
    final sock = FakeSocket(url, headers);
    sockets.add(sock);
    return sock;
  }
}

class FakeGateway {
  FakeGateway({required this.info, this.stateBody = const {}});
  Map<String, Object?> info;
  Map<String, Object?> stateBody;
  final Map<String, Object?> bodies = {};

  http.Client client() => MockClient((req) async {
    if (req.body.isNotEmpty) {
      final decoded = jsonDecode(req.body);
      if (decoded is Map<String, Object?>) bodies[req.url.path] = decoded;
    }
    if (req.url.path.endsWith('/messages')) {
      return _json({'messages': []});
    }
    if (req.url.path.endsWith('/state')) {
      return _json(stateBody);
    }
    if (req.url.path.endsWith('/stats')) {
      return _json({
        'data': {
          'cost': 0.42,
          'contextUsage': {
            'percent': 12.5,
            'tokens': 20000,
            'contextWindow': 160000,
          },
        },
      });
    }
    if (req.url.path.endsWith('/catalog/models')) {
      return _json({
        'models': [
          {
            'provider': 'z-ai',
            'id': 'other-model',
            'selector': 'z-ai/other-model',
            'name': 'Other Model',
            'contextWindow': 32000,
            'maxTokens': 8192,
            'reasoning': false,
            'thinking': null,
            'input': [],
            'cost': {'input': 0, 'output': 0},
          },
        ],
      });
    }
    if (req.url.path.endsWith('/commands')) {
      return _json({
        'data': {'commands': []},
      });
    }
    return _json(info);
  });
}

ProviderContainer _container({
  DateTime Function()? now,
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
    now: now ?? DateTime.now,
  );
  final container = ProviderContainer(
    overrides: [
      // A fixed catalog so the picker needs no gateway round-trip.
      modelsStoreProvider.overrideWith(
        () => _SeededModelsStore([
          CatalogModel(
            provider: 'z-ai',
            id: 'other-model',
            selector: 'z-ai/other-model',
            name: 'Other Model',
            contextWindow: 32000,
            maxTokens: 8192,
            reasoning: false,
            thinking: null,
            input: const [],
            cost: const ModelCost(
              input: 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
            ),
          ),
        ]),
      ),
      connectionPrefsProvider.overrideWithValue(
        MemoryPrefs(const [
          ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
        ]),
      ),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
      sessionEnvProvider.overrideWith((ref) async => env),
    ],
  );
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
    ],
    activeId: 'c1',
  );
  addTearDown(container.dispose);
  return container;
}

Map<String, Object?> infoJson() => {
  'gwId': 'abc',
  'cwd': '/work/project-x',
  'thinkingLevel': 'low',
  'lastEventSeq': 0,
  'isStreaming': false,
  'model': {'id': 'm1', 'name': 'Model One', 'provider': 'p'},
  'contextUsage': {'percent': 10, 'tokens': 16000, 'contextWindow': 160000},
};

Future<void> _pumpSheet(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: Material(
          color: OmpTheme.data(OmpPreset.terminal)
              .extension<OmpTokens>()!
              .surface,
          child: const SessionInfoSheet(gwId: 'abc'),
        ),
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
  for (final on in [true, false]) {
    testWidgets('the Model section says whether advisor is on ($on)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final gateway = FakeGateway(info: {...infoJson(), 'advisor': on});
      final container = _container(gateway: gateway, hub: SocketHub());
      await _pumpSheet(tester, container);

      final row = find.ancestor(
        of: find.text('Advisor'),
        matching: find.byType(Row),
      );
      expect(
        find.descendant(of: row.first, matching: find.text(on ? 'On' : 'Off')),
        findsOneWidget,
      );
    });
  }

  testWidgets('shows where the open session runs and its model', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway(info: infoJson());
    final container = _container(gateway: gateway, hub: SocketHub());
    await _pumpSheet(tester, container);

    final text = find.byType(Text);
    String allText() =>
        tester.widgetList<Text>(text).map((t) => t.data ?? '').join('\n');
    expect(allText(), contains('/work/project-x'));
    expect(allText(), contains('Model One'));
    expect(allText(), contains('abc'));
  });

  testWidgets(
    'picking from the thinking dropdown calls setThinking with that level',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final gateway = FakeGateway(info: infoJson());
      final container = _container(gateway: gateway, hub: SocketHub());
      await _pumpSheet(tester, container);

      // A dropdown showing the current level ('low' in infoJson).
      final field = find.byType(DropdownButtonFormField<String>);
      expect(field, findsOneWidget);
      expect(
        find.descendant(of: field, matching: find.text('low')),
        findsOneWidget,
      );
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      // The full API.md list, including the two the chips used to miss.
      expect(find.text('xhigh').last, findsOneWidget);
      expect(find.text('max').last, findsOneWidget);
      await tester.tap(find.text('medium').last);
      await tester.pumpAndSettle();
      expect(gateway.bodies['/api/sessions/abc/thinking'], {'level': 'medium'});
    },
  );

  testWidgets('Change opens the model picker and a pick calls setModel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway(info: infoJson());
    final container = _container(gateway: gateway, hub: SocketHub());
    await _pumpSheet(tester, container);

    await tester.tap(find.text('Change'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    // The picker lists the catalog model; picking it switches the session.
    await tester.tap(find.textContaining('Other Model'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(gateway.bodies['/api/sessions/abc/model'], {
      'provider': 'z-ai',
      'modelId': 'other-model',
    });
  });

  testWidgets('Stats for nerds shows the last turn TTFT, tokens per second, '
      'reconnects and last event seq', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway(info: infoJson());
    // A fake client clock: tokens per second is timed client-side only
    // (review #11), so the harness drives the clock between events.
    var ms = 1_700_000_000_000;
    final container = _container(
      gateway: gateway,
      hub: hub,
      now: () => DateTime.fromMillisecondsSinceEpoch(ms),
    );

    // The sheet watches the controller, which opens the session and socket.
    await _pumpSheet(tester, container);

    // Script a finished turn through the stream. Frames deliver
    // synchronously, so the clock is advanced BEFORE each frame.
    hub.current.frame(1, {'type': 'agent_start'}); // clock t0
    ms += 600; // first assistant delta
    hub.current.frame(2, {
      'type': 'message_update',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
        'timestamp': 1700000001000, // server clock, ignored for timing
      },
    });
    hub.current.frame(3, {
      'type': 'message_end',
      'messageId': 'm-1',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
        'usage': {'output': 50, 'input': 10},
        'duration': 5000,
        'timestamp': 1700000001000,
      },
    });
    ms += 5000; // turn end: 5.6s after start, 5s of streaming
    hub.current.frame(4, {'type': 'agent_end'});
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    final stats = container.read(sessionControllerProvider('abc')).turnStats;
    expect(stats, isNotNull);

    await tester.tap(find.text('Stats for nerds'));
    await tester.pump();
    await tester.pump();

    final all = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');
    expect(all, contains('Time to first token'));
    expect(all, contains('Tokens per second'));
    expect(all, contains('10.0 tok/s'));
    expect(all, contains('Stream reconnects'));
    expect(all, contains('Last event seq'));
  });
}

/// Store override so the picker sees a fixed catalog (no gateway).
class _SeededModelsStore extends ModelsStore {
  _SeededModelsStore(this.seed);
  final List<CatalogModel> seed;
  @override
  ModelsState build() => ModelsState(models: seed, ready: true);
}
