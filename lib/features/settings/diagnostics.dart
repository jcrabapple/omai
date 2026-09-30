// Diagnostics checks, the logic half of the Diagnostics page (the Relay
// capability card, folded in per PLAN E2a). Pure and injectable: each check
// is a function returning a status, so unit tests inject fakes and no widget
// is needed. Five checks: gateway reachable (/healthz), signed in (/api/me,
// a 401 means the token was rejected), WebSocket (the same probe the
// connection test uses: first frame must be auth_ok; unknown, not failed,
// when there is no live session to probe), omp version (/api/system), and
// the model catalog (/api/catalog/models, which can take up to a minute).
// Rows run concurrently and update independently. The bearer token never
// appears in any result, message, or log.

import '../../api/errors.dart';

typedef HealthCheck = Future<bool> Function();
typedef MeCheck = Future<String> Function();
typedef SessionLister = Future<List<String>> Function();
typedef WsProber = Future<bool> Function();
typedef SystemFetcher = Future<Map<String, Object?>> Function();
typedef CatalogFetcher = Future<bool> Function();

enum CheckStatus { pass, fail, unknown }

class CheckResult {
  const CheckResult(this.status, {this.hint});
  final CheckStatus status;

  /// Short fix hint shown on failure (or on unknown, where it explains why
  /// the check could not run).
  final String? hint;

  static const CheckResult pass = CheckResult(CheckStatus.pass);
}

/// One diagnosable leg of the gateway path.
class DiagnosticCheck {
  const DiagnosticCheck({required this.id, required this.label, required this.run});
  final String id;
  final String label;
  final Future<CheckResult> Function() run;
}

class Diagnostics {
  /// Builds the five checks from injectable seams. In the app the seams come
  /// from a [GatewayClient]-shaped client and the shared WS probe; in tests
  /// they are fakes.
  Diagnostics({
    required this.gatewayReachable,
    required this.signedIn,
    required this.liveSessionIds,
    required this.wsProbe,
    required this.system,
    required this.modelCatalog,
  });

  final HealthCheck gatewayReachable;
  final MeCheck signedIn;
  final SessionLister liveSessionIds;
  final WsProber wsProbe;
  final SystemFetcher system;
  final CatalogFetcher modelCatalog;

  /// The checks in display order.
  List<DiagnosticCheck> get checks => [
    DiagnosticCheck(id: 'gateway', label: 'Gateway reachable', run: _checkGateway),
    DiagnosticCheck(id: 'auth', label: 'Signed in', run: _checkSignedIn),
    DiagnosticCheck(id: 'websocket', label: 'WebSocket', run: _checkWebSocket),
    DiagnosticCheck(id: 'omp', label: 'omp', run: _checkOmp),
    DiagnosticCheck(id: 'catalog', label: 'Model catalog', run: _checkCatalog),
  ];

  Future<CheckResult> _checkGateway() async {
    try {
      return await gatewayReachable()
          ? CheckResult.pass
          : const CheckResult(CheckStatus.fail,
              hint: 'The gateway answered, but not with a healthy status.');
    } catch (_) {
      return const CheckResult(CheckStatus.fail,
          hint: 'Check the URL and that the gateway is running.');
    }
  }

  Future<CheckResult> _checkSignedIn() async {
    try {
      final method = await signedIn();
      return method.isNotEmpty
          ? CheckResult.pass
          : const CheckResult(CheckStatus.fail,
              hint: 'The gateway did not confirm the sign-in method.');
    } on AuthError {
      return const CheckResult(CheckStatus.fail,
          hint: 'The token was rejected. Sign in again.');
    } catch (_) {
      return const CheckResult(CheckStatus.fail,
          hint: 'Could not ask the gateway. Check the connection.');
    }
  }

  Future<CheckResult> _checkWebSocket() async {
    List<String> live;
    try {
      live = await liveSessionIds();
    } catch (_) {
      return const CheckResult(CheckStatus.unknown,
          hint: 'Could not list sessions, so the WebSocket leg is unchecked.');
    }
    // Unknown, not failed: there is nothing to probe yet.
    if (live.isEmpty) {
      return const CheckResult(CheckStatus.unknown,
          hint: 'Checked once a session is live.');
    }
    try {
      return await wsProbe()
          ? CheckResult.pass
          : const CheckResult(CheckStatus.fail,
              hint: 'A proxy may be blocking WebSockets.');
    } catch (_) {
      return const CheckResult(CheckStatus.fail,
          hint: 'A proxy may be blocking WebSockets.');
    }
  }

  Future<CheckResult> _checkOmp() async {
    try {
      final json = await system();
      final omp = json['omp'];
      final version = omp is Map ? omp['version'] : null;
      return version is String && version.isNotEmpty
          ? CheckResult.pass
          : const CheckResult(CheckStatus.fail,
              hint: 'omp was not found on the gateway host.');
    } catch (_) {
      return const CheckResult(CheckStatus.fail,
          hint: 'Could not read the gateway host information.');
    }
  }

  Future<CheckResult> _checkCatalog() async {
    try {
      return await modelCatalog()
          ? CheckResult.pass
          : const CheckResult(CheckStatus.fail,
              hint: 'The catalog came back empty or malformed.');
    } catch (_) {
      return const CheckResult(CheckStatus.fail,
          hint: 'The catalog request failed. It can take up to a minute.');
    }
  }
}
