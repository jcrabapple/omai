// Shared fakes for the settings widget tests: an in-memory ReviewedKv, a
// fixed token store, in-memory ConnectionPrefs seeded with an active
// connection, and a FakeGateway MockClient serving the endpoints the
// settings pages hit. No network; the pattern follows
// test/features/new_session/new_session_sheet_test.dart.

import 'dart:convert';


import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ohmypi/api/client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';

http.Response json(Object? body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class MemoryKv implements ReviewedKv {
  final Map<String, String> map = {};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

class FixedTokenStore implements TokenStore {
  const FixedTokenStore();
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
  List<ConnectionRecord>? lastSaved;
  @override
  Future<List<ConnectionRecord>> load() async => records;
  @override
  Future<void> save(List<ConnectionRecord> connections) async {
    lastSaved = connections;
  }
}

const activeRecord = ConnectionRecord(id: 'c1', url: 'https://gw.test', label: 'Test');

/// The endpoints the settings pages read. Each map key is a path; values are
/// bodies (status 200) or, for non-200, a status int.
class FakeGateway {
  FakeGateway(this.routes);
  final Map<String, Object?> routes;
  final List<String> requested = [];

  http.Client client() => MockClient((req) async {
    requested.add(req.url.path);
    final route = routes[req.url.path];
    if (route == null) return json({'error': 'not found'}, status: 404);
    if (route is int) return json({'error': 'nope'}, status: route);
    return json(route);
  });


  /// A container wired to the active connection backed by this fake. The
  /// caller owns disposing (addTearDown).
  ProviderContainer get container => ProviderContainer(overrides: [
    connectionPrefsProvider.overrideWithValue(MemoryPrefs(const [activeRecord])),
    tokenStoreProvider.overrideWithValue(const FixedTokenStore()),
    gatewayClientFactoryProvider.overrideWithValue(
      (url, token) => GatewayClient(baseUrl: url, token: token, client: client()),
    ),
  ]);
}
