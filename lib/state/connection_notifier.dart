// Connection state: the signed-in connection, the connection test, sign in
// and sign out. Storage seams are injected via providers so tests use mocks.

import 'dart:async';
import 'dart:io' show WebSocket;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/errors.dart';
import 'connection_store.dart';

final connectionPrefsProvider =
    Provider<ConnectionPrefs>((ref) => SharedPrefsConnectionPrefs());

final tokenStoreProvider = Provider<TokenStore>((ref) => const SecureTokenStore());

/// Client factory seam so tests can hand back a GatewayClient wrapping a
/// MockClient http.Client.
typedef GatewayClientFactory = GatewayClient Function(String baseUrl, String token);

final gatewayClientFactoryProvider = Provider<GatewayClientFactory>(
    (ref) => (baseUrl, token) => GatewayClient(baseUrl: baseUrl, token: token));

/// Overridable in tests; the default opens a real WebSocket with the bearer
/// header and reports whether the upgrade + first frame path works.
final wsProbeProvider = Provider<WsProbe>((ref) => defaultWsProbe);

Future<bool> defaultWsProbe(Uri uri, Map<String, String> headers) async {
  WebSocket? ws;
  try {
    ws = await WebSocket.connect(uri.toString(), headers: headers)
        .timeout(const Duration(seconds: 10));
    // Wait briefly for the server to speak (auth_ok or a close); either proves
    // the WS leg works end to end.
    await ws.first.timeout(const Duration(seconds: 10));
    return true;
  } on TimeoutException {
    return false;
  } catch (_) {
    return false;
  } finally {
    await ws?.close();
  }
}

/// One saved gateway connection.
class ConnectionState {
  const ConnectionState({
    this.connections = const [],
    this.activeId,
    this.busy = false,
    this.testOutcome,
  });

  final List<ConnectionRecord> connections;
  final String? activeId;

  /// True while loading state or running a connection test.
  final bool busy;

  /// Copy shown on the Connect screen after a test. Null clears it.
  final String? testOutcome;

  ConnectionRecord? get active =>
      connections.isEmpty ? null : connections.where((c) => c.id == activeId).firstOrNull;

  bool get signedIn => active != null;

  ConnectionState copyWith({
    List<ConnectionRecord>? connections,
    String? activeId,
    bool clearActiveId = false,
    bool? busy,
    String? testOutcome,
    bool clearTestOutcome = false,
  }) {
    return ConnectionState(
      connections: connections ?? this.connections,
      activeId: clearActiveId ? null : (activeId ?? this.activeId),
      busy: busy ?? this.busy,
      testOutcome: clearTestOutcome ? null : (testOutcome ?? this.testOutcome),
    );
  }
}

/// Result of a successful sign-in flow.
class SignedIn {
  const SignedIn(this.record, this.token);
  final ConnectionRecord record;
  final String token;
}

class ConnectionNotifier extends Notifier<ConnectionState> {
  @override
  ConnectionState build() {
    _load();
    return const ConnectionState(busy: true);
  }

  ConnectionPrefs get _prefs => ref.read(connectionPrefsProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);

  Future<void> _load() async {
    final connections = await _prefs.load();
    if (connections.isEmpty) {
      state = state.copyWith(connections: const [], clearActiveId: true, busy: false);
      return;
    }
    // The most recently added connection is the default.
    var activeId = connections.last.id;
    final token = await _tokens.read(activeId);
    if (token == null || token.isEmpty) activeId = '';
    state = state.copyWith(
      connections: connections,
      activeId: activeId.isEmpty ? null : activeId,
      busy: false,
    );
  }

  /// Runs the three-legged connection test: /healthz, /api/me, then a
  /// WebSocket probe against a live session when one exists. Returns copy for
  /// the screen; failure classes each get their own line.
  Future<String> testConnection(String url, String token) async {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (clean.isEmpty) return 'Enter the gateway URL first.';
    if (token.trim().isEmpty) return 'Enter the gateway token first.';
    state = state.copyWith(busy: true, clearTestOutcome: true);
    final outcome = await _runTest(clean, token.trim());
    state = state.copyWith(busy: false, testOutcome: outcome);
    return outcome;
  }

  Future<String> _runTest(String url, String token) async {
    final make = ref.read(gatewayClientFactoryProvider);
    final client = make(url, token);
    try {
      await client.healthz();
    } on AuthError {
      return 'The gateway rejected the token. Check it and try again.';
    } on LockedOut {
      return 'Too many failed attempts. This IP is locked out for a while.';
    } on EdgeRefused {
      return 'The edge (Cloudflare) refused the request. Check the URL.';
    } on Offline {
      return 'Could not reach the gateway. Check the URL and your network.';
    } on GatewayClientError catch (e) {
      return 'The gateway answered with an error: ${e.message}';
    }
    try {
      await client.me();
    } on AuthError {
      return 'The gateway rejected the token. Check it and try again.';
    } on LockedOut {
      return 'Too many failed attempts. This IP is locked out for a while.';
    } on EdgeRefused {
      return 'The edge (Cloudflare) refused the request. Check the URL.';
    } on Offline {
      return 'Reached the gateway but the API call timed out. Try again.';
    } on GatewayClientError catch (e) {
      return 'The gateway answered with an error: ${e.message}';
    }

    // WebSocket leg: probe a live session if there is one, else say so.
    try {
      final list = await client.sessions(limit: 1, includeSaved: false);
      if (list.live.isEmpty) {
        return 'HTTP OK, WebSocket not verified (no live session).';
      }
      final id = list.live.first.gwId;
      final probe = ref.read(wsProbeProvider);
      final ok = await probe(
        client.wsUrl('/omp-ws/$id'),
        {'Authorization': 'Bearer $token'},
      );
      return ok
          ? 'Connection OK. HTTP and WebSocket both verified.'
          : 'HTTP OK, but the WebSocket failed. Proxies can pass HTTP and break WS.';
    } on GatewayClientError catch (e) {
      return 'HTTP OK, WebSocket not verified (listing sessions failed: ${e.message}).';
    }
  }

  /// Persists the connection and token after a successful test. The caller
  /// decides whether to test first; signing in does not run the test itself.
  Future<SignedIn> signIn({
    required String url,
    required String label,
    required String token,
  }) async {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    final id = _idFor(clean);
    final record = ConnectionRecord(id: id, url: clean, label: label.trim());
    final connections = [
      ...state.connections.where((c) => c.id != id),
      record,
    ];
    await _prefs.save(connections);
    await _tokens.write(id, token.trim());
    state = state.copyWith(
      connections: connections,
      activeId: id,
      busy: false,
      clearTestOutcome: true,
    );
    return SignedIn(record, token.trim());
  }

  Future<void> signOut() async {
    final active = state.active;
    if (active != null) {
      await _tokens.delete(active.id);
      final connections =
          state.connections.where((c) => c.id != active.id).toList();
      await _prefs.save(connections);
      state = state.copyWith(connections: connections, clearActiveId: true);
    }
    state = state.copyWith(clearTestOutcome: true);
  }

  /// Stable, non-secret id from the URL: host + port (+ path hash on clash).
  String _idFor(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? url;
    final port = (uri?.hasPort ?? false) ? ':${uri!.port}' : '';
    var id = '$host$port';
    if (state.connections.any((c) => c.id == id && c.url != url)) {
      id = '$id-${url.hashCode.toUnsigned(16).toRadixString(16)}';
    }
    return id;
  }
}

final connectionNotifierProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(ConnectionNotifier.new);
