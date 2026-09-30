// Review #1 regression: on a cold start the launch intent (notification tap,
// share, shortcut) arrives while the connection notifier is still busy. It
// must be queued and dispatched once sign-in settles, never dropped because
// `signedIn` was still false on the first frame.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/app/app.dart';
import 'package:omai/composer/drafts.dart';
import 'package:omai/features/session/session_screen.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/session_controller.dart';
import 'package:omai/state/sessions_store.dart';
import 'package:omai/stream/scheduler.dart';
import 'package:omai/stream/session_stream.dart';

import '../stream/fakes.dart';

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

/// Loads on demand: the completer models credentials that are still loading
/// while the first frame (and the launch intent) arrive.
class _GatedPrefs implements ConnectionPrefs {
  final Completer<List<ConnectionRecord>> gate = Completer();
  @override
  Future<List<ConnectionRecord>> load() => gate.future;
  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

class _MemoryReviewedKv implements ReviewedKv {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

class _MemoryDraftKv implements DraftKv {
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
  FakeSocket get current => sockets.last;
  Future<StreamSocket> factory(Uri url, Map<String, String> headers) async {
    final sock = FakeSocket(url, headers);
    sockets.add(sock);
    return sock;
  }
}

void main() {
  testWidgets(
    'a cold-start notification tap is queued until sign-in settles, then '
    'opens the session',
    (tester) async {
      final hub = SocketHub();
      final env = SessionEnv(
        client: GatewayClient(
          baseUrl: 'https://g',
          token: 'tok',
          client: MockClient((req) async {
            if (req.url.path.endsWith('/messages')) {
              return _json({'messages': []});
            }
            if (req.url.path.endsWith('/state')) return _json({});
            if (req.url.path.endsWith('/stats')) return _json({'data': {}});
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
          }),
        ),
        baseUrl: 'https://g',
        token: 'tok',
        socketFactory: hub.factory,
        scheduler: const SystemScheduler(),
      );
      final prefs = _GatedPrefs();
      final container = ProviderContainer(
        overrides: [
          connectionPrefsProvider.overrideWithValue(prefs),
          tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
          sessionsPollIntervalProvider.overrideWithValue(
            const Duration(hours: 1),
          ),
          reviewedKvProvider.overrideWithValue(_MemoryReviewedKv()),
          draftKvProvider.overrideWithValue(_MemoryDraftKv()),
          gatewayClientFactoryProvider.overrideWith(
            (ref) =>
                (baseUrl, token) => GatewayClient(
                  baseUrl: baseUrl,
                  token: token,
                  client: MockClient((req) async => _json({})),
                ),
          ),
          sessionEnvProvider.overrideWith((ref) async => env),
        ],
      );
      addTearDown(container.dispose);

      // The cold-start intent: a notification tap for session abc.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('us.snakepit.omai/native'),
        (call) async {
          if (call.method == 'getInitialIntent') {
            return {'type': 'openSession', 'gwId': 'abc'};
          }
          // launchHandled and everything else.
          return 'ok';
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('us.snakepit.omai/native'),
          null,
        );
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const OmpApp()),
      );
      await tester.pump();
      await tester.pump();

      // Credentials still loading (busy): the intent must NOT be dropped,
      // but it also cannot navigate yet.
      expect(find.byType(SessionScreen), findsNothing);
      expect(
        find.text('Connect to a gateway'),
        findsOneWidget,
        reason: 'still on the connect screen while credentials load',
      );

      // Sign-in settles.
      prefs.gate.complete(const [
        ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
      ]);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.byType(SessionScreen),
        findsOneWidget,
        reason: 'the queued launch is dispatched once the notifier settles',
      );
    },
  );
}
