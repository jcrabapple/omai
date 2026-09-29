// Connection state: the signed-in connection, the connection test, sign in
// and sign out. Storage seams are injected via providers so tests use mocks.

import 'dart:async';
import 'dart:convert';
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
/// header and reports whether the upgrade + auth_ok path works.
final wsProbeProvider = Provider<WsProbe>((ref) => defaultWsProbe);

/// The gateway sends `{"seq":0,"event":{"type":"auth_ok",...}}` immediately
/// after accepting the upgrade. A socket that upgrades but never delivers
/// auth_ok is broken (proxy, wrong path, mid-auth hang), so silence fails.
/// [timeout] is injectable so tests do not wait the full 10 seconds.
Future<bool> defaultWsProbe(Uri uri, Map<String, String> headers,
    {Duration timeout = const Duration(seconds: 10)}) async {
  WebSocket? ws;
  try {
    ws = await WebSocket.connect(uri.toString(), headers: headers)
        .timeout(timeout);
  } catch (_) {
    return false;
  }
  bool firstFrameIsAuthOk(Object frame) {
    try {
      final decoded = jsonDecode(frame as String);
      final event = decoded is Map ? decoded['event'] : null;
      return event is Map && event['type'] == 'auth_ok';
    } catch (_) {
      return false;
    }
  }

  final done = Completer<bool>();
  late final StreamSubscription<dynamic> sub;
  sub = ws.listen(
    (frame) {
      if (!done.isCompleted) done.complete(firstFrameIsAuthOk(frame));
    },
    onDone: () {
      // Any close before auth_ok is a failure, including the gateway's
      // 4401 "bad token" close.
      if (!done.isCompleted) done.complete(false);
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete(false);
    },
    cancelOnError: true,
  );
  try {
    return await done.future.timeout(timeout);
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
    this.loadError,
  });

  final List<ConnectionRecord> connections;
  final String? activeId;

  /// True while loading state or running a connection test.
  final bool busy;

  /// Outcome shown on the Connect screen after a test. Null clears it.
  final ConnectionTestResult? testResult;

  /// Set when loading saved connections failed; sign-in still works.
  final String? loadError;

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
    String? loadError,
    bool clearLoadError = false,
  }) {
    return ConnectionState(
      connections: connections ?? this.connections,
      activeId: clearActiveId ? null : (activeId ?? this.activeId),
      busy: busy ?? this.busy,
      testResult: clearTestResult ? null : (testResult ?? this.testResult),
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
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
  /// How long sign-in and sign-out wait for the initial load before
  /// proceeding anyway. Injectable so tests do not wait 4 seconds.
  static Duration settleBound = const Duration(seconds: 4);

  /// Completes once the initial load has applied its state (or failed, or
  /// hit the bound). Never throws: an errored load must not surface as a
  /// sign-in failure.
  Future<void> get _settled {
    final load = _loadFuture;
    if (load == null) return Future<void>.value();
    return load
        .then<void>((_) {}, onError: (_) {})
        .timeout(settleBound, onTimeout: () => Future<void>.value());
  }

  Future<void>? _loadFuture;
  Future<SignedIn?>? _signInFuture;

  @override
  ConnectionState build() {
    _loadFuture = _load();
    return const ConnectionState(busy: true);
  }

  ConnectionPrefs get _prefs => ref.read(connectionPrefsProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);

  Future<void> _load() async {
    List<ConnectionRecord> connections;
    try {
      connections = await _prefs.load();
    } catch (_) {
      // Yield first: a synchronous load() throw happens inside build(),
      // before the notifier is initialised enough to write state.
      await Future<void>.delayed(Duration.zero);
      if (!ref.mounted) return;
      // Leave sign-in usable: no connections loaded, but the screen works.
      state = state.copyWith(
        connections: const [],
        clearActiveId: true,
        busy: false,
        loadError: 'Could not load saved connections.',
      );
      return;
    }
    if (!ref.mounted) return;
    state = state.copyWith(clearLoadError: true);
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
    if (clean.isEmpty) {
      const result = TestError('Enter the gateway URL first.');
      state = state.copyWith(busy: false, testResult: result);
      return result;
    }
    if (token.trim().isEmpty) {
      const result = TestError('Enter the gateway token first.');
      state = state.copyWith(busy: false, testResult: result);
      return result;
    }
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
  /// A second concurrent sign-in returns the first one's future instead of
  /// running again (no duplicate records from a double tap). Returns null
  /// when the notifier was disposed mid-sign-in: nothing to report then.
  Future<SignedIn?> signIn({
    required String url,
    required String label,
    required String token,
  }) {
    final inFlight = _signInFuture;
    if (inFlight != null) return inFlight;
    final future = _signIn(url: url, label: label, token: token);
    _signInFuture = future;
    return future.whenComplete(() => _signInFuture = null);

  }

  Future<SignedIn?> _signIn({
    required String url,
    required String label,
    required String token,
  }) async {
    await _settled;
    state = state.copyWith(busy: true);
    try {
      if (!ref.mounted) return null;
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
      if (!ref.mounted) return null;
      await _tokens.write(record.id, token.trim());
      if (!ref.mounted) return null;
      state = state.copyWith(
        connections: connections,
        activeId: record.id,
        busy: false,
        clearTestResult: true,
      );
      return SignedIn(record, token.trim());
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
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
      // Both writes run regardless of mounted: persisting the removal must
      // not depend on whether the widget tree is still alive.
      await _tokens.delete(active.id);
      await _prefs.save(connections);
      return;
    }
    state = state.copyWith(clearTestResult: true);
  }

  /// Normalised URL comparison: scheme and host case-insensitive, trailing
  /// slashes and scheme-default ports ignored.
  bool _sameUrl(String a, String b) => normalizeGatewayUrl(a) == normalizeGatewayUrl(b);
}

/// Canonical form of a gateway URL: lowercase scheme and host, drop the port
/// only when it is the scheme's default (80/http, 443/https), strip trailing
/// slashes from the path, keep non-default ports and paths.
String normalizeGatewayUrl(String url) {
  final trimmed = url.trim();
  final u = Uri.tryParse(trimmed);
  if (u == null || !u.hasScheme || u.host.isEmpty) {
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }
  final scheme = u.scheme.toLowerCase();
  final host = u.host.toLowerCase();
  final isDefaultPort = u.hasPort &&
      ((scheme == 'http' && u.port == 80) || (scheme == 'https' && u.port == 443));
  final dropPort = !u.hasPort || isDefaultPort;
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return '$scheme://$host${dropPort ? '' : ':${u.port}'}$path';
}

final connectionNotifierProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(ConnectionNotifier.new);
