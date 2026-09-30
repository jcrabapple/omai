// SessionController retry-with-images (E2b): a failed send keeps its images
// keyed by local id, retrySend resends text AND images, and an images-only
// failed send (empty text) retries too. Pure controller test against the
// fake gateway from the shared stream fakes harness.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/session_controller.dart';
import 'package:omai/state/sessions_store.dart';
import 'package:omai/stream/scheduler.dart';
import 'package:omai/transcript/items.dart' show UserItem;

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

class _Kv implements ReviewedKv {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

ProviderContainer _container({
  required Set<String> failPaths,
  required List<Map<String, Object?>> bodiesOut,
  required void Function(int) onPrompt,
}) {
  final env = SessionEnv(
    client: GatewayClient(
      baseUrl: 'https://g',
      token: 'tok',
      client: MockClient((req) async {
        if (req.body.isNotEmpty) {
          final decoded = jsonDecode(req.body);
          if (decoded is Map<String, Object?>) {
            bodiesOut.add({...decoded, '_path': req.url.path});
          }
        }
        if (failPaths.any(req.url.path.endsWith)) {
          return _json({'error': 'nope'}, status: 500);
        }
        if (req.url.path.endsWith('/prompt')) {
          onPrompt(1);
          return _json({
            'gwId': 'abc',
            'cwd': '/work/x',
            'isStreaming': false,
            'lastEventSeq': 0,
          });
        }
        if (req.url.path.endsWith('/messages')) return _json({'messages': []});
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
      }),
    ),
    baseUrl: 'https://g',
    token: 'tok',
    socketFactory: (url, headers) async =>
        throw UnimplementedError('no socket in this test'),
    scheduler: const SystemScheduler(),
  );
  final container = ProviderContainer(overrides: [
    connectionPrefsProvider.overrideWithValue(
      _Prefs(const [ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')]),
    ),
    tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
    reviewedKvProvider.overrideWithValue(_Kv()),
    sessionsPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
    sessionEnvProvider.overrideWith((ref) async => env),
  ]);
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
    ],
    activeId: 'c1',
  );
  return container;
}

class _Prefs implements ConnectionPrefs {
  _Prefs(this.records);
  final List<ConnectionRecord> records;
  @override
  Future<List<ConnectionRecord>> load() async => records;
  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

const pngImages = [
  {'type': 'image', 'data': 'aGk=', 'mimeType': 'image/png'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('retrySend resends a failed send with its images', () async {
    final fails = <String>{'/prompt'};
    final bodies = <Map<String, Object?>>[];
    final container = _container(
      failPaths: fails,
      bodiesOut: bodies,
      onPrompt: (_) {},
    );
    addTearDown(container.dispose);
    container.listen(sessionControllerProvider('abc'), (_, _) {});
    await Future<void>.delayed(Duration.zero);
    final controller =
        container.read(sessionControllerProvider('abc').notifier);
    // Let build's _open settle; it fails fast on the missing socket, but the
    // state still exists for send().
    await Future<void>.delayed(Duration.zero);

    final ok = await controller.send('look at this', images: pngImages);
    expect(ok, isFalse, reason: 'the gateway 500s');
    fails.clear();
    final retried = await container
        .read(sessionControllerProvider('abc').notifier)
        .retrySend(_failedLocalId(container));
    expect(retried, isTrue);
    final prompts =
        bodies.where((b) => b['_path'] == '/api/sessions/abc/prompt').toList();
    // The first entry is the failed original send; the last is the retry.
    expect(prompts, hasLength(2));
    expect(prompts.last['message'], 'look at this');
    expect(prompts.last['images'], pngImages);
  });

  test('retrySend accepts an images-only failed send and resends the images',
      () async {
    final fails = <String>{'/prompt'};
    final bodies = <Map<String, Object?>>[];
    final container = _container(
      failPaths: fails,
      bodiesOut: bodies,
      onPrompt: (_) {},
    );
    addTearDown(container.dispose);
    container.listen(sessionControllerProvider('abc'), (_, _) {});
    await Future<void>.delayed(Duration.zero);

    await container
        .read(sessionControllerProvider('abc').notifier)
        .send('', images: pngImages);
    fails.clear();
    final localId = _failedLocalId(container);
    final ok =
        await container.read(sessionControllerProvider('abc').notifier).retrySend(localId);
    expect(ok, isTrue, reason: 'an images-only failed send retries');
    final prompts =
        bodies.where((b) => b['_path'] == '/api/sessions/abc/prompt');
    expect(prompts.last['message'], '');
    expect(prompts.last['images'], pngImages);
  });

  test('retrySend without text or images still refuses', () async {
    final bodies = <Map<String, Object?>>[];
    final container = _container(
      failPaths: const {},
      bodiesOut: bodies,
      onPrompt: (_) {},
    );
    addTearDown(container.dispose);
    container.listen(sessionControllerProvider('abc'), (_, _) {});
    await Future<void>.delayed(Duration.zero);
    final ok =
        await container.read(sessionControllerProvider('abc').notifier).retrySend('missing');
    expect(ok, isFalse);
  });

  test('image retention is bounded to the three most recent failed sends',
      () async {
    final fails = <String>{'/prompt'};
    final bodies = <Map<String, Object?>>[];
    final container = _container(
      failPaths: fails,
      bodiesOut: bodies,
      onPrompt: (_) {},
    );
    addTearDown(container.dispose);
    container.listen(sessionControllerProvider('abc'), (_, _) {});
    await Future<void>.delayed(Duration.zero);
    final controller =
        container.read(sessionControllerProvider('abc').notifier);

    final failedIds = <String>[];
    for (var i = 0; i < 4; i++) {
      await controller.send('', images: pngImages);
      failedIds.add(_newestFailedLocalId(container));
    }
    fails.clear();

    // The oldest images-only failed send had its images evicted: the retry
    // is refused (no text, no images left).
    final oldest =
        await controller.retrySend(failedIds.first);
    expect(oldest, isFalse,
        reason: 'only the most recent 3 failed sends keep their images');

    // The most recent one still retries with its images.
    final promptsBefore =
        bodies.where((b) => b['_path'] == '/api/sessions/abc/prompt').length;
    final newest = await controller.retrySend(failedIds.last);
    expect(newest, isTrue);
    final prompts = bodies
        .where((b) => b['_path'] == '/api/sessions/abc/prompt')
        .toList();
    expect(prompts.length, promptsBefore + 1);
    expect(prompts.last['images'], pngImages);
  });
}

String _failedLocalId(ProviderContainer container) {
  final state = container.read(sessionControllerProvider('abc'));
  for (final item in state.transcript.items) {
    final id = item is UserItem && item.failed == true ? item.localId : null;
    if (id != null) return id;
  }
  fail('no failed item found');
}

String _newestFailedLocalId(ProviderContainer container) {
  final state = container.read(sessionControllerProvider('abc'));
  String? last;
  for (final item in state.transcript.items) {
    if (item is UserItem && item.failed == true) last = item.localId;
  }
  if (last == null) fail('no failed item found');
  return last;
}
