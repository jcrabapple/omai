import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/features/home/home_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/theme/presets.dart';

class MockConnectionPrefs extends Mock implements ConnectionPrefs {}

class MockTokenStore extends Mock implements TokenStore {}

http.Response _json(Object? body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  late MockConnectionPrefs prefs;
  late MockTokenStore tokens;

  setUpAll(() {
    registerFallbackValue(const ConnectionRecord(id: 'x', url: 'u', label: 'l'));
  });

  setUp(() {
    prefs = MockConnectionPrefs();
    tokens = MockTokenStore();
    when(() => prefs.load()).thenAnswer((_) async => [
          const ConnectionRecord(
              id: 'abc123', url: 'https://gw.example.com', label: 'gw'),
        ]);
    when(() => prefs.save(any())).thenAnswer((_) async {});
    when(() => tokens.read('abc123')).thenAnswer((_) async => 'tok');
    when(() => tokens.write(any(), any())).thenAnswer((_) async {});
    when(() => tokens.delete(any())).thenAnswer((_) async {});
  });

  Future<http.Response> Function(http.Request) handler =
      (_) async => _json({});

  Widget wrap() => ProviderScope(
        overrides: [
          connectionPrefsProvider.overrideWithValue(prefs),
          tokenStoreProvider.overrideWithValue(tokens),
          gatewayClientFactoryProvider.overrideWithValue((url, token) =>
              GatewayClient(
                  baseUrl: url,
                  token: token,
                  client: MockClient((req) async => handler(req)),
                  timeout: const Duration(seconds: 2))),
        ],
        child: MaterialApp(
            theme: OmpTheme.data(OmpPreset.paper), home: const HomeScreen()),
      );

  testWidgets('renders live and saved session titles with live dot',
      (tester) async {
    handler = (_) async => _json({
          'live': [
            {
              'gwId': 'l1',
              'cwd': '/home/user/projects/demo',
              'ompSessionName': 'fix the login bug',
            },
            {
              'gwId': 'l2',
              'cwd': '/home/user/projects/ohmypi-gateway',
              'ompSessionName': '',
            },
          ],
          'saved': [
            {
              'file': '/home/user/.omp/agent/sessions/a.jsonl',
              'mtime': 1,
              'sizeBytes': 10,
              'cwdFolder': 'misc',
              'cwd': '/home/user/projects/old',
              'title': 'older chat',
              'running': false,
            },
          ],
        });

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('fix the login bug'), findsOneWidget);
    // Empty ompSessionName falls back to the cwd basename.
    expect(find.text('ohmypi-gateway'), findsOneWidget);
    expect(find.text('older chat'), findsOneWidget);
  });

  testWidgets('a gateway failure shows the error view', (tester) async {
    handler = (_) async => _json({'error': 'boom'}, status: 503);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Could not reach the gateway. Pull to retry.'),
        findsOneWidget);
  });

  testWidgets('an empty list shows the empty state', (tester) async {
    handler = (_) async => _json({'live': [], 'saved': []});

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('No sessions yet.'), findsOneWidget);
  });
}
