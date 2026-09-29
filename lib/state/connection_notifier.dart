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
  } on TimeoutException {
    return false;
  } catch (_) {
    return false;
  }
  // Wait for the server to speak or close. `ws.first` throws StateError when
  // the server closes without a data frame, so use listen(onData, onDone)
  // instead and read the close code off the socket.
  final done = Completer<bool>();
  late final StreamSubscription<dynamic> sub;
  sub = ws.listen(
    (_) {
      if (!done.isCompleted) done.complete(true);
    },
    onDone: () {
      // A clean server close after a successful upgrade proves the WS leg
      // works, except 4401: the gateway's "bad token" close.
      if (!done.isCompleted) done.complete(ws?.closeCode != 4401);
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete(false);
    },
    cancelOnError: true,
  );
  try {
    return await done.future.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    return false;
  } finally {
    await sub.cancel();
    await ws.close();
  }
}

/// Result of the three-legged connection test. Structured so the screen can
/// colour it without sniffing the text ('OK' appears in failure copy too).
sealed class ConnectionTestResult {
  const ConnectionTestResult(this.message);
  final String message;
}

/// HTTP and WebSocket both verified.
class TestOk extends ConnectionTestResult {
  const TestOk(super.message);
}

/// HTTP works; the WebSocket leg could not be checked (no live session, or
/// the listing failed). Not a failure, but not a confirmation either.
class TestWsUnverified extends ConnectionTestResult {
  const TestWsUnverified(super.message);
}

/// HTTP works but the WebSocket leg failed: proxies can pass HTTP and break WS.
class TestWsFailed extends ConnectionTestResult {
  const TestWsFailed(super.message);
}

/// The gateway rejected the token, locked the IP out, or was unreachable.
class TestError extends ConnectionTestResult {
  const TestError(super.message);
}

/// One saved gateway connection.
class ConnectionState {
  const ConnectionState({
    this.connections = const [],
    this.activeId,
    this.busy = false,
    this.testResult,
  });

  final List<ConnectionRecord> connections;
  final String? activeId;

  /// True while loading state or running a connection test.
  final bool busy;

  /// Outcome shown on the Connect screen after a test. Null clears it.
  final ConnectionTestResult? testResult;

  ConnectionRecord? get active =>
      connections.isEmpty ? null : connections.where((c) => c.id == activeId).firstOrNull;

  bool get signedIn => active != null;

  ConnectionState copyWith({
    List<ConnectionRecord>? connections,
    String? activeId,
    bool clearActiveId = false,
    bool? busy,
    ConnectionTestResult? testResult,
    bool clearTestResult = false,
  }) {
    return ConnectionState(
      connections: connections ?? this.connections,
      activeId: clearActiveId ? null : (activeId ?? this.activeId),
      busy: busy ?? this.busy,
      testResult: clearTestResult ? null : (testResult ?? this.testResult),
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
  /// Completes once the initial load has applied its state. Sign-in and
  /// sign-out await it so they never race a pending load (which used to
  /// overwrite the freshly signed-in connection when it finished late).
  Future<void> get _settled => _loadFuture ?? Future<void>.value();
  Future<void>? _loadFuture;

  @override
  ConnectionState build() {
    _loadFuture = _load();
    return const ConnectionState(busy: true);
  }

  ConnectionPrefs get _prefs => ref.read(connectionPrefsProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);

  Future<void> _load() async {
    final connections = await _prefs.load();
    if (!ref.mounted) return;
    if (connections.isEmpty) {
      state = state.copyWith(connections: const [], clearActiveId: true, busy: false);
      return;
    }
    // The most recently added connection is the default.
    var activeId = connections.last.id;
    final token = await _tokens.read(activeId);
    if (!ref.mounted) return;
    if (token == null || token.isEmpty) activeId = '';
    state = state.copyWith(
      connections: connections,
      activeId: activeId.isEmpty ? null : activeId,
      busy: false,
    );
  }

  /// Runs the three-legged connection test: /healthz, /api/me, then a
  /// WebSocket probe against a live session when one exists. Returns a
  /// structured outcome; failure classes each get their own line.
  Future<ConnectionTestResult> testConnection(String url, String token) async {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (clean.isEmpty) return const TestError('Enter the gateway URL first.');
    if (token.trim().isEmpty) return const TestError('Enter the gateway token first.');
    state = state.copyWith(busy: true, clearTestResult: true);
    final result = await _runTest(clean, token.trim());
    if (!ref.mounted) return result;
    state = state.copyWith(busy: false, testResult: result);
    return result;
  }

  Future<ConnectionTestResult> _runTest(String url, String token) async {
    final make = ref.read(gatewayClientFactoryProvider);
    final client = make(url, token);
    try {
      await client.healthz();
    } on AuthError {
      return const TestError('The gateway rejected the token. Check it and try again.');
    } on LockedOut {
      return const TestError('Too many failed attempts. This IP is locked out for a while.');
    } on EdgeRefused {
      return const TestError('The edge (Cloudflare) refused the request. Check the URL.');
    } on Offline {
      return const TestError('Could not reach the gateway. Check the URL and your network.');
    } on GatewayClientError catch (e) {
      return TestError('The gateway answered with an error: ${e.message}');
    }
    try {
      await client.me();
    } on AuthError {
      return const TestError('The gateway rejected the token. Check it and try again.');
    } on LockedOut {
      return const TestError('Too many failed attempts. This IP is locked out for a while.');
    } on EdgeRefused {
      return const TestError('The edge (Cloudflare) refused the request. Check the URL.');
    } on Offline {
      return const TestError('Reached the gateway but the API call timed out. Try again.');
    } on GatewayClientError catch (e) {
      return TestError('The gateway answered with an error: ${e.message}');
    }

    // WebSocket leg: probe a live session if there is one, else say so.
    try {
      final list = await client.sessions(limit: 1, includeSaved: false);
      if (list.live.isEmpty) {
        return const TestWsUnverified('HTTP OK, WebSocket not verified (no live session).');
      }
      final id = list.live.first.gwId;
      final probe = ref.read(wsProbeProvider);
      final ok = await probe(
        client.wsUrl('/omp-ws/$id'),
        {'Authorization': 'Bearer $token'},
      );
      return ok
          ? const TestOk('Connection OK. HTTP and WebSocket both verified.')
          : const TestWsFailed('HTTP OK, but the WebSocket failed. Proxies can pass HTTP and break WS.');
    } on GatewayClientError catch (e) {
      return TestWsUnverified('HTTP OK, WebSocket not verified (listing sessions failed: ${e.message}).');
    }
  }

  /// Persists the connection and token after a successful test. The caller
  /// decides whether to test first; signing in does not run the test itself.
  Future<SignedIn> signIn({
    required String url,
    required String label,
    required String token,
  }) async {
    await _settled;
    if (!ref.mounted) throw StateError('ConnectionNotifier was disposed during sign in.');
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    // Reuse the permanent id when this URL already has a record; create one
    // random id for a genuinely new connection. Ids never derive from other
    // connections in state, so the secure-storage token key cannot drift.
    final existing = state.connections.where((c) => _sameUrl(c.url, clean)).firstOrNull;
    final record = existing != null
        ? ConnectionRecord(id: existing.id, url: clean, label: label.trim())
        : ConnectionRecord.create(url: clean, label: label.trim());
    final connections = [
      ...state.connections.where((c) => c.id != record.id),
      record,
    ];
    await _prefs.save(connections);
    if (!ref.mounted) throw StateError('ConnectionNotifier was disposed during sign in.');
    await _tokens.write(record.id, token.trim());
    if (!ref.mounted) throw StateError('ConnectionNotifier was disposed during sign in.');
    state = state.copyWith(
      connections: connections,
      activeId: record.id,
      busy: false,
      clearTestResult: true,
    );
    return SignedIn(record, token.trim());
  }

  Future<void> signOut() async {
    await _settled;
    if (!ref.mounted) return;
    final active = state.active;
    if (active != null) {
      final connections =
          state.connections.where((c) => c.id != active.id).toList();
      // Update state first: the UI must not depend on how long storage takes.
      state = state.copyWith(
          connections: connections, clearActiveId: true, clearTestResult: true);
      await _tokens.delete(active.id);
      if (!ref.mounted) return;
      await _prefs.save(connections);
      return;
    }
    state = state.copyWith(clearTestResult: true);
  }

  /// Normalised URL comparison: scheme and host case-insensitive, trailing
  /// slashes and default port ignored.
  bool _sameUrl(String a, String b) => _normalizeUrl(a) == _normalizeUrl(b);

  String _normalizeUrl(String url) {
    var u = url.trim().replaceAll(RegExp(r'/+$'), '');
    final schemeEnd = u.indexOf('://');
    if (schemeEnd > 0) {
      u = '${u.substring(0, schemeEnd).toLowerCase()}${u.substring(schemeEnd)}';
    }
    return u.replaceFirst(RegExp(r':80/'), '/').replaceFirst(RegExp(r':443/'), '/');
  }
}

final connectionNotifierProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(ConnectionNotifier.new);
