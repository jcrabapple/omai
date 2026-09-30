// Ported from web/src/lib/state/models.svelte.ts behaviour (groupModels,
// matchesModel, stale-first catalog): a failed refresh keeps the last list on
// screen, the error lands in `error`, a retry recovers, and a connection
// change resets and refetches. The gateway is a MockClient; no network.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/api/models.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/models_store.dart';

/// Drain the microtask chain (token read, mock HTTP, store state writes).
Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

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

/// Scriptable /api/catalog/models with a response queue.
class CatalogGateway {
  final List<http.Response> _responses = [];
  final List<http.Request> requests = [];

  void queue(Object? body, {int status = 200}) =>
      _responses.add(_json(body, status: status));

  http.Client client() => MockClient((req) async {
    requests.add(req);
    return _responses.removeAt(0);
  });
}

Map<String, Object?> modelJson({
  String provider = 'openrouter',
  String id = 'm-1',
  String name = 'Model One',
}) => {
  'provider': provider,
  'id': id,
  'selector': '$provider/$id',
  'name': name,
  'contextWindow': 200000,
  'maxTokens': 8192,
  'reasoning': true,
  'cost': {'input': 3, 'output': 15, 'cacheRead': 0, 'cacheWrite': 0},
};

CatalogModel model({
  String provider = 'openrouter',
  String id = 'm-1',
  String name = 'Model One',
}) => CatalogModel.fromJson(modelJson(provider: provider, id: id, name: name));

ProviderContainer _container(
  CatalogGateway gateway, {
  List<ConnectionRecord> connections = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      connectionPrefsProvider.overrideWithValue(MemoryPrefs(connections)),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      gatewayClientFactoryProvider.overrideWith(
        (ref) =>
            (baseUrl, token) => GatewayClient(
              baseUrl: baseUrl,
              token: token,
              client: gateway.client(),
            ),
      ),
    ],
  );
  if (connections.isNotEmpty) {
    container.read(connectionNotifierProvider.notifier).state = ConnectionState(
      connections: connections,
      activeId: connections.last.id,
    );
  }
  return container;
}

void main() {
  test('matchesModel requires every word across provider, id and name', () {
    final m = model(name: 'Claude Sonnet');
    expect(matchesModel(m, ''), isTrue);
    expect(matchesModel(m, 'claude'), isTrue);
    expect(matchesModel(m, 'CLAUDE sonnet'), isTrue);
    expect(matchesModel(m, 'openrouter claude'), isTrue);
    expect(matchesModel(m, 'claude haiku'), isFalse);
    expect(matchesModel(m, '   '), isTrue);
  });

  test('groupModels groups by provider alphabetically, name-sorted within', () {
    final groups = groupModels([
      model(provider: 'zai', id: 'b', name: 'B'),
      model(provider: 'anthropic', id: 'y', name: 'y model'),
      model(provider: 'anthropic', id: 'x', name: 'A model'),
    ]);
    expect(groups.map((g) => g.provider).toList(), ['anthropic', 'zai']);
    expect(groups.first.models.map((m) => m.name).toList(), [
      'A model',
      'y model',
    ]);
  });

  test('groupModels filters by query', () {
    final groups = groupModels([
      model(provider: 'anthropic', id: 'sonnet', name: 'Claude Sonnet'),
      model(provider: 'openai', id: 'gpt', name: 'GPT'),
    ], 'sonnet');
    expect(groups, hasLength(1));
    expect(groups.single.provider, 'anthropic');
  });

  test('first fetch populates the catalog and clears refreshing', () async {
    final gateway = CatalogGateway()
      ..queue({
        'models': [modelJson(id: 'm-1')],
      });
    final container = _container(
      gateway,
      connections: const [
        ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(modelsStoreProvider.notifier).refresh();

    final state = container.read(modelsStoreProvider);
    expect(state.ready, isTrue);
    expect(state.refreshing, isFalse);
    expect(state.error, isNull);
    expect(state.models.single.id, 'm-1');
    expect(
      container.read(modelsStoreProvider.notifier).find('openrouter', 'm-1'),
      isNotNull,
    );
    expect(
      container.read(modelsStoreProvider.notifier).find('openrouter', 'nope'),
      isNull,
    );
  });

  test('a failed first fetch sets error and stays not-ready', () async {
    final container = _containerWithClient(
      MockClient((_) async => _json({'error': 'boom'}, status: 500)),
      connections: const [
        ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(modelsStoreProvider.notifier).refresh();

    final state = container.read(modelsStoreProvider);
    expect(state.ready, isFalse);
    expect(state.error, isNotNull);
    expect(state.models, isEmpty);
  });

  test('stale-first: a failed refresh keeps the loaded list and sets error; retry recovers', () async {
    final gateway = CatalogGateway()
      ..queue({
        'models': [modelJson(id: 'm-1')],
      })
      ..queue({'error': 'rate limited'}, status: 429)
      ..queue({
        'models': [
          modelJson(id: 'm-1'),
          modelJson(id: 'm-2', name: 'Model Two'),
        ],
      });
    final container = _container(
      gateway,
      connections: const [
        ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(modelsStoreProvider.notifier).refresh();
    expect(container.read(modelsStoreProvider).models, hasLength(1));

    await container.read(modelsStoreProvider.notifier).refresh();
    await _settle();
    var state = container.read(modelsStoreProvider);
    expect(state.ready, isTrue, reason: 'the stale list stays on screen');
    expect(state.models.single.id, 'm-1');
    expect(state.error, 'rate limited');
    expect(state.refreshing, isFalse);

    container.read(modelsStoreProvider.notifier).retry();
    await _settle();
    state = container.read(modelsStoreProvider);
    expect(state.error, isNull);
    expect(state.models.map((m) => m.id), ['m-1', 'm-2']);
  });

  test('a connection change resets the catalog and refetches', () async {
    final gateway = CatalogGateway()
      ..queue({
        'models': [modelJson(id: 'old')],
      })
      ..queue({
        'models': [modelJson(id: 'new')],
      });
    final container = _container(
      gateway,
      connections: [
        const ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(modelsStoreProvider.notifier).refresh();
    expect(container.read(modelsStoreProvider).models.single.id, 'old');

    container.read(connectionNotifierProvider.notifier).state = ConnectionState(
      connections: const [
        ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
        ConnectionRecord(id: 'c2', url: 'https://g2', label: 'G2'),
      ],
      activeId: 'c2',
    );
    await _settle();
    await container.read(modelsStoreProvider.notifier).refresh();
    expect(container.read(modelsStoreProvider).models.single.id, 'new');
  });
}

ProviderContainer _containerWithClient(
  http.Client client, {
  List<ConnectionRecord> connections = const [],
}) => _containerFromFactory(
  (baseUrl, token) =>
      GatewayClient(baseUrl: baseUrl, token: token, client: client),
  connections: connections,
);

ProviderContainer _containerFromFactory(
  GatewayClientFactory factory, {
  List<ConnectionRecord> connections = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      connectionPrefsProvider.overrideWithValue(MemoryPrefs(connections)),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      gatewayClientFactoryProvider.overrideWithValue(factory),
    ],
  );
  if (connections.isNotEmpty) {
    container.read(connectionNotifierProvider.notifier).state = ConnectionState(
      connections: connections,
      activeId: connections.last.id,
    );
  }
  return container;
}
