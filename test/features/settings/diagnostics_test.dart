// Diagnostics logic tests: pure checks with injected fakes, no widgets.
// Covers each check passing, failing with its hint, and the WebSocket
// unknown state when there is no live session; a 401 fails the signed-in
// check with the re-sign-in hint; rows run concurrently so a slow catalog
// does not block the others.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/api/errors.dart';
import 'package:omai/features/settings/diagnostics.dart';

Diagnostics makeDiagnostics({
  Object? gateway = true,
  Object? me = 'bearer',
  List<String> live = const ['gw-1'],
  Object? ws = true,
  Object? system = const {
    'omp': {'version': '1.2.3'},
  },
  Future<bool> Function()? catalog,
  Completer<bool>? slowCatalog,
  List<String>? probedIds,
}) {
  Future<bool> unwrap(Object? v) async {
    if (v is Exception) throw v;
    if (v is Future) return await v;
    return v == true;
  }

  Future<bool> Function() catalogFn = catalog ??
      () async {
        if (slowCatalog != null) return await slowCatalog.future;
        return true;
      };

  return Diagnostics(
    gatewayReachable: () => unwrap(gateway),
    signedIn: () async {
      final r = await unwrap(me);
      return r == true ? 'bearer' : (me as String);
    },
    liveSessionIds: () async => live,
    wsProbe: (gwId) {
      probedIds?.add(gwId);
      return unwrap(ws);
    },
    system: () async {
      final v = system;
      if (v is Exception) throw v;
      return v as Map<String, Object?>;
    },
    modelCatalog: catalogFn,
  );
}

void main() {
  Map<String, CheckResult> byId(List<DiagnosticCheck> checks, List<CheckResult> results) => {
    for (var i = 0; i < checks.length; i++) checks[i].id: results[i],
  };

  test('all pass on a healthy gateway', () async {
    final d = makeDiagnostics();
    final checks = d.checks;
    final results = await Future.wait([for (final c in checks) c.run()]);
    final r = byId(checks, results);
    expect(r['gateway']!.status, CheckStatus.pass);
    expect(r['auth']!.status, CheckStatus.pass);
    expect(r['websocket']!.status, CheckStatus.pass);
    expect(r['omp']!.status, CheckStatus.pass);
    expect(r['catalog']!.status, CheckStatus.pass);
  });

  test('gateway unreachable fails with the URL hint', () async {
    final d = makeDiagnostics(gateway: const Offline('down'));
    final r = await d.checks.first.run();
    expect(r.status, CheckStatus.fail);
    expect(r.hint, contains('gateway is running'));
  });

  test('a 401 fails signed in with the sign-in-again hint', () async {
    final d = makeDiagnostics(me: const AuthError('401'));
    final r = await d.checks[1].run();
    expect(r.status, CheckStatus.fail);
    expect(r.hint, contains('Sign in again'));
  });

  test('no live session makes the WebSocket check unknown, not failed', () async {
    final d = makeDiagnostics(live: const [], ws: false);
    final r = await d.checks[2].run();
    expect(r.status, CheckStatus.unknown);
    expect(r.hint, contains('once a session is live'));
  });

  test('a failed probe on a live session fails with the proxy hint', () async {
    final d = makeDiagnostics(ws: false);
    final r = await d.checks[2].run();
    expect(r.status, CheckStatus.fail);
    expect(r.hint, contains('WebSockets'));
  });

  test('the probe receives the session id found by the lister, once', () async {
    final probed = <String>[];
    final d = makeDiagnostics(live: const ['gw-9'], ws: true, probedIds: probed);
    final r = await d.checks[2].run();
    expect(r.status, CheckStatus.pass);
    expect(probed, ['gw-9'],
        reason: 'the probe uses the listed id, with no second listing');
  });

  test('omp without a version fails with the omp hint', () async {
    final d = makeDiagnostics(system: const {
      'omp': {'version': ''},
    });
    final r = await d.checks[3].run();
    expect(r.status, CheckStatus.fail);
    expect(r.hint, contains('omp was not found'));
  });

  test('a catalog failure fails with the catalog hint', () async {
    final d = makeDiagnostics(catalog: () async => throw const Offline('no'));
    final r = await d.checks[4].run();
    expect(r.status, CheckStatus.fail);
    expect(r.hint, isNotNull);
  });

  test('rows are independent: a slow catalog does not block the others', () async {
    final slow = Completer<bool>();
    final d = makeDiagnostics(slowCatalog: slow);
    final checks = d.checks;
    final results = <CheckResult>[];
    final futures = [
      for (final c in checks)
        c.run().then((r) {
          results.add(r);
          return r;
        }),
    ];
    // Give the fast checks a beat; the catalog is still pending.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(results.length, 4, reason: 'the fast checks resolved on their own');
    slow.complete(true);
    await Future.wait(futures);
    expect(results.length, 5);
  });
}
