// Resume-from-history tests: tapping a saved row POSTs {resumeFrom},
// alreadyLive opens the existing live session instead of duplicating,
// cwdFallback surfaces a notice naming the dead folder and the cwd used, and
// errors show as a SnackBar. The gateway is a MockClient; no network.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/api/models.dart';
import 'package:omai/app/app.dart';
import 'package:omai/composer/drafts.dart';
import 'package:omai/features/session/session_screen.dart';
import 'package:omai/features/sessions/sessions_screen.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/session_controller.dart';
import 'package:omai/state/sessions_store.dart';
import 'package:omai/stream/scheduler.dart';
import 'package:omai/theme/presets.dart';

import '../../stream/fakes.dart';

http.Response _json(Object? body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

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

class _MemoryKv implements ReviewedKv {
  final Map<String, String> _map = {};
  @override
  Future<String?> get(String key) async => _map[key];
  @override
  Future<void> set(String key, String value) async => _map[key] = value;
}

class _MemoryDraftKv implements DraftKv {
  final Map<String, String> _map = {};
  @override
  Future<String?> get(String key) async => _map[key];
  @override
  Future<void> set(String key, String value) async => _map[key] = value;
  @override
  Future<void> remove(String key) async => _map.remove(key);
}

/// Scriptable gateway: the sessions listing plus a create/resume POST whose
/// response each test controls. [listGate] holds every GET /api/sessions
/// after the first (the initial load) until completed; [listStatusAfterFirst]
/// makes subsequent listings fail with that status.
class ResumeGateway {
  ResumeGateway(
      {this.saved = const [],
      this.resumeResponse,
      this.listGate,
      this.listStatusAfterFirst});
  List<Map<String, Object?>> saved;
  Map<String, Object?>? resumeResponse;
  Completer<void>? listGate;
  int? listStatusAfterFirst;
  final List<Object?> bodies = [];
  int listCalls = 0;

  http.Client client() => MockClient((req) async {
        if (req.method == 'POST' && req.url.path == '/api/sessions') {
          bodies.add(jsonDecode(req.body));
          return _json(resumeResponse ??
              {
                'gwId': 'gw-resumed',
                'cwd': '/work/prompter',
                'approvalMode': 'yolo',
              });
        }
        if (req.url.path == '/api/sessions') {
          // Only the listing AFTER the resume POST is scripted: the initial
          // screen load may make several listing calls before that.
          if (bodies.isNotEmpty) {
            final gate = listGate;
            if (gate != null) await gate.future;
            final status = listStatusAfterFirst;
            if (status != null) {
              return _json({'error': 'nope'}, status: status);
            }
          }
          return _json({'live': const [], 'saved': saved});
        }
        if (req.url.path.endsWith('/messages')) {
          return _json({'messages': []});
        }
        return _json({'live': const [], 'saved': const []});
      });
}

ProviderContainer _container(ResumeGateway gateway) {
  final env = SessionEnv(
      client: GatewayClient(
          baseUrl: 'https://g', token: 'tok', client: gateway.client()),
      baseUrl: 'https://g',
      token: 'tok',
      socketFactory: (url, headers) async {
        final sock = FakeSocket(url, headers);
        return sock;
      },
      scheduler: const SystemScheduler());
  final container = ProviderContainer(overrides: [
    reviewedKvProvider.overrideWithValue(_MemoryKv()),
    draftKvProvider.overrideWithValue(_MemoryDraftKv()),
    connectionPrefsProvider.overrideWithValue(MemoryPrefs(const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')
    ])),
    tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
    sessionsPollIntervalProvider
        .overrideWithValue(const Duration(hours: 1)),
    gatewayClientFactoryProvider.overrideWith((ref) => (baseUrl, token) =>
        GatewayClient(baseUrl: baseUrl, token: token,
            client: gateway.client())),
    sessionEnvProvider.overrideWith((ref) async => env),
  ]);
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
      connections:
          const [ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')],
      activeId: 'c1');
  return container;
}

Map<String, Object?> _savedJson(
        {String file = '/t/one.jsonl', String cwd = '/work/prompter'}) =>
    {
      'file': file,
      'mtime': DateTime.now().millisecondsSinceEpoch / 1000,
      'sizeBytes': 10,
      'cwdFolder': cwd,
      'cwd': cwd,
      'title': 'Old session',
      'running': false,
    };

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: OmpTheme.data(OmpPreset.terminal),
      navigatorObservers: [ompRouteObserver],
      home: const SessionsScreen(),
    ),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('tapping a history row resumes it via resumeFrom and opens it',
      (tester) async {
    final gateway = ResumeGateway(
        saved: [_savedJson()],
        resumeResponse: {
          'gwId': 'gw-resumed',
          'cwd': '/work/prompter',
          'approvalMode': 'yolo',
        });
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Old session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(gateway.bodies.single,
        {'resumeFrom': '/t/one.jsonl'});
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(
        tester.widget<SessionScreen>(find.byType(SessionScreen)).gwId,
        'gw-resumed');
  });

  testWidgets('alreadyLive opens the existing live session, no duplicate',
      (tester) async {
    final gateway = ResumeGateway(
        saved: [_savedJson()],
        resumeResponse: {
          'gwId': 'gw-live-1',
          'cwd': '/work/prompter',
          'approvalMode': 'yolo',
          'alreadyLive': true,
        });
    final container = _container(gateway);
    addTearDown(container.dispose);
    // The file is already open by this live session.
    container
        .read(sessionsStoreProvider.notifier)
        .patch(SessionInfo.fromJson({'gwId': 'gw-live-1', 'cwd': '/work/prompter'}));
    await _pump(tester, container);

    await tester.tap(find.text('Old session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SessionScreen), findsOneWidget);
    expect(
        tester.widget<SessionScreen>(find.byType(SessionScreen)).gwId,
        'gw-live-1');
    // No cwdFallback notice for a normal alreadyLive resume.
    expect(find.textContaining('no longer exists'), findsNothing);
  });

  testWidgets('cwdFallback shows a notice with the dead folder and cwd used',
      (tester) async {
    final gateway = ResumeGateway(
        saved: [_savedJson(cwd: '/gone/proj')],
        resumeResponse: {
          'gwId': 'gw-resumed',
          'cwd': '/home/user/projects',
          'approvalMode': 'yolo',
          'cwdFallback': true,
        });
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Old session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('/gone/proj'), findsOneWidget);
    expect(find.textContaining('/home/user/projects'), findsOneWidget);
  });

  testWidgets('a failed resume shows the error as a SnackBar', (tester) async {
    final saved = [_savedJson()];
    final client = MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/api/sessions') {
        return _json({'error': 'session limit reached (8); stop one first'},
            status: 429);
      }
      if (req.url.path.endsWith('/messages')) {
        return _json({'messages': []});
      }
      return _json({'live': const [], 'saved': saved});
    });
    final container = ProviderContainer(overrides: [
      reviewedKvProvider.overrideWithValue(_MemoryKv()),
      draftKvProvider.overrideWithValue(_MemoryDraftKv()),
      connectionPrefsProvider.overrideWithValue(MemoryPrefs(const [
        ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')
      ])),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      sessionsPollIntervalProvider
          .overrideWithValue(const Duration(hours: 1)),
      gatewayClientFactoryProvider.overrideWith((ref) => (baseUrl, token) =>
          GatewayClient(baseUrl: baseUrl, token: token, client: client)),
      sessionEnvProvider.overrideWith((ref) async => SessionEnv(
          client: GatewayClient(baseUrl: 'https://g', token: 'tok', client: client),
          baseUrl: 'https://g',
          token: 'tok',
          socketFactory: (url, headers) async => FakeSocket(url, headers),
          scheduler: const SystemScheduler())),
    ]);
    container.read(connectionNotifierProvider.notifier).state = ConnectionState(
        connections:
            const [ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')],
        activeId: 'c1');
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Old session'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('session limit reached'), findsOneWidget);
    expect(find.byType(SessionScreen), findsNothing);
  });

  testWidgets('resume opens the session immediately; the listing refresh '
      'runs in the background', (tester) async {
    final gateway = ResumeGateway(
      saved: [_savedJson()],
      listGate: Completer<void>(), // the post-resume listing never completes
      resumeResponse: {
        'gwId': 'gw-resumed',
        'cwd': '/work/prompter',
        'approvalMode': 'yolo',
      },
    );
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    // Debug
    // ignore: avoid_print
    print('DBG saved=${container.read(sessionsStoreProvider).saved.length} '
        'err=${container.read(sessionsStoreProvider).error} '
        'calls=${gateway.listCalls}');

    await tester.tap(find.text('Old session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The refresh is still hung, but the session must already be open.
    expect(find.byType(SessionScreen), findsOneWidget,
        reason: 'opening must not wait on the listing refresh');
    expect(gateway.bodies.single, {'resumeFrom': '/t/one.jsonl'});

    // Let the hung request settle before the container is disposed.
    gateway.listGate!.complete();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('a failing listing refresh does not block or error the resume',
      (tester) async {
    final gateway = ResumeGateway(
      saved: [_savedJson()],
      listStatusAfterFirst: 504,
      resumeResponse: {
        'gwId': 'gw-resumed',
        'cwd': '/work/prompter',
        'approvalMode': 'yolo',
      },
    );
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    // Debug
    // ignore: avoid_print
    debugPrint('DBG saved=${container.read(sessionsStoreProvider).saved.length} '
        'err=${container.read(sessionsStoreProvider).error}');

    await tester.tap(find.text('Old session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SessionScreen), findsOneWidget,
        reason: 'a failed background refresh must not abort the open');
    expect(find.byType(SnackBar), findsNothing,
        reason: 'the resume itself succeeded; no error surfaced');
  });
}
