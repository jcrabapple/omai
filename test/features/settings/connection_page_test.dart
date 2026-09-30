// Connection page widget tests: rows render from a faked /api/system and
// /api/me, the sign-out confirm calls signOut, and cancel does not.

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/features/settings/connection_page.dart';
import 'package:omai/theme/presets.dart';
import 'package:omai/state/connection_notifier.dart';

import 'fakes.dart';

Future<FakeGateway> pump(WidgetTester tester, FakeGateway fake) async {
  final container = fake.container;
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: ConnectionPage()),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  testWidgets('renders the /api/system and /api/me rows', (tester) async {
    await pump(
      tester,
      FakeGateway({
        '/api/system': {
          'gateway': {
            'version': '1.4.0',
            'uptimeSec': 90000,
            'maxSessions': 8,
            'idleReapSec': 1800,
          },
          'omp': {'version': '2.0.1', 'configFile': '/home/user/.omp/config.json'},
          'liveSessions': 2,
        },
        '/api/me': {'authenticated': true, 'method': 'bearer'},
      }),
    );
    expect(find.text('1.4.0'), findsOneWidget);
    expect(find.text('1 d 1 h'), findsOneWidget);
    expect(find.text('2.0.1'), findsOneWidget);
    expect(find.text('2 of 8'), findsOneWidget);
    expect(find.text('Access token'), findsOneWidget);
    expect(find.text('/home/user/.omp/config.json'), findsOneWidget);
    expect(find.text('https://gw.test'), findsOneWidget);
  });

  testWidgets('an error from the gateway shows with Retry', (tester) async {
    final fake = await pump(
      tester,
      FakeGateway({'/api/system': 500, '/api/me': 500}),
    );
    expect(find.text('Retry'), findsOneWidget);
    fake.routes['/api/system'] = {
      'gateway': {'version': 'ok'},
      'omp': {'version': 'ok'},
    };
    fake.routes['/api/me'] = {'method': 'bearer'};
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('ok'), findsNWidgets(2));
  });

  testWidgets('sign out confirms, then signs out', (tester) async {
    final container = FakeGateway({
      '/api/system': {
        'gateway': {'version': '1'},
        'omp': {'version': '1'},
      },
      '/api/me': {'method': 'bearer'},
    }).container;
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: ConnectionPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(connectionNotifierProvider).signedIn, isTrue);

    await tester.tap(find.byKey(const ValueKey('connection-signout')));
    await tester.pumpAndSettle();
    expect(find.text('Live sessions keep running on the gateway.'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('connection-signout-cancel')));
    await tester.pumpAndSettle();
    expect(container.read(connectionNotifierProvider).signedIn, isTrue);

    await tester.tap(find.byKey(const ValueKey('connection-signout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connection-signout-confirm')));
    await tester.pumpAndSettle();
    expect(container.read(connectionNotifierProvider).signedIn, isFalse);
  });
}
