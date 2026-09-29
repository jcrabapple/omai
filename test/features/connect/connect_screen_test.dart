import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/features/connect/connect_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/theme/tokens.dart';

class MockConnectionPrefs extends Mock implements ConnectionPrefs {}

class MockTokenStore extends Mock implements TokenStore {}

http.Response _json(Object? body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  late MockConnectionPrefs prefs;
  late MockTokenStore tokens;

  setUpAll(() {
    registerFallbackValue(
      const ConnectionRecord(id: 'x', url: 'u', label: 'l'),
    );
  });

  setUp(() {
    prefs = MockConnectionPrefs();
    tokens = MockTokenStore();
    when(() => prefs.load()).thenAnswer((_) async => const []);
    when(() => prefs.save(any())).thenAnswer((_) async {});
    when(() => tokens.read(any())).thenAnswer((_) async => null);
    when(() => tokens.write(any(), any())).thenAnswer((_) async {});
    when(() => tokens.delete(any())).thenAnswer((_) async {});
  });

  Future<void> pump(
    WidgetTester tester, {
    required WsProbe probe,
    required http.Response sessionsResponse,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionPrefsProvider.overrideWithValue(prefs),
          tokenStoreProvider.overrideWithValue(tokens),
          gatewayClientFactoryProvider.overrideWithValue(
            (url, token) => GatewayClient(
              baseUrl: url,
              token: token,
              client: MockClient((req) async {
                if (req.url.path == '/healthz') return _json({'ok': true});
                if (req.url.path == '/api/me') {
                  return _json({'method': 'bearer'});
                }
                if (req.url.path == '/api/sessions') return sessionsResponse;
                return _json({});
              }),
              timeout: const Duration(seconds: 2),
            ),
          ),
          wsProbeProvider.overrideWithValue(probe),
        ],
        child: MaterialApp(
          theme: OmpTheme.data(OmpPreset.paper),
          home: const ConnectScreen(),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byType(TextField).first,
      'https://gw.example.com',
    );
    await tester.enterText(find.byType(TextField).at(1), 'tok');
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
  }

  OmpTokens themeTokens(WidgetTester tester) =>
      Theme.of(tester.element(find.text('Test connection')))
          .extension<OmpTokens>()!;

  Color renderedColor(WidgetTester tester, String message) =>
      tester.widget<Text>(find.text(message)).style!.color!;

  testWidgets('tapping Test with an empty URL shows the validation message', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionPrefsProvider.overrideWithValue(prefs),
          tokenStoreProvider.overrideWithValue(tokens),
          gatewayClientFactoryProvider.overrideWithValue(
            (url, token) => GatewayClient(
              baseUrl: url,
              token: token,
              client: MockClient((_) async => _json({})),
              timeout: const Duration(seconds: 2),
            ),
          ),
        ],
        child: MaterialApp(
          theme: OmpTheme.data(OmpPreset.paper),
          home: const ConnectScreen(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(find.text('Enter the gateway URL first.'), findsOneWidget);
  });

  testWidgets('the form starts right under the title (no dead gap)', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionPrefsProvider.overrideWithValue(prefs),
          tokenStoreProvider.overrideWithValue(tokens),
          gatewayClientFactoryProvider.overrideWithValue(
            (url, token) => GatewayClient(
              baseUrl: url,
              token: token,
              client: MockClient((_) async => _json({})),
            ),
          ),
        ],
        child: MaterialApp(
          theme: OmpTheme.data(OmpPreset.paper),
          home: const ConnectScreen(),
        ),
      ),
    );
    await tester.pump();

    // Regression: the Center wrapper vertically centred the form, leaving a
    // large empty band under the Connect title. The intro copy must sit
    // within ~100dp of the top of the body.
    final dy = tester
        .getTopLeft(
          find.text(
            'Point the app at your gateway. The token is stored in the '
            'Android keystore, never in plain prefs.',
          ),
        )
        .dy;
    expect(
      dy,
      lessThan(56 /* app bar */ + 100),
      reason: 'the form must not float to the vertical middle',
    );
  });

  testWidgets('a failed WS leg shows red even though the copy contains OK', (
    tester,
  ) async {
    await pump(
      tester,
      probe: (_, _) async => false,
      sessionsResponse: _json({
        'live': [
          {'gwId': 'abc', 'cwd': '/home/user/x'},
        ],
        'saved': [],
      }),
    );
    const message =
        'HTTP OK, but the WebSocket failed. Proxies can pass HTTP and break WS.';
    expect(find.text(message), findsOneWidget);
    expect(renderedColor(tester, message), themeTokens(tester).err);
    expect(renderedColor(tester, message), isNot(themeTokens(tester).ok));
  });

  testWidgets('a verified connection shows green', (tester) async {
    await pump(
      tester,
      probe: (_, _) async => true,
      sessionsResponse: _json({
        'live': [
          {'gwId': 'abc', 'cwd': '/home/user/x'},
        ],
        'saved': [],
      }),
    );
    const message = 'Connection OK. HTTP and WebSocket both verified.';
    expect(renderedColor(tester, message), themeTokens(tester).ok);
  });

  testWidgets('an unverified WS leg shows the warn colour, not green', (
    tester,
  ) async {
    await pump(
      tester,
      probe: (_, _) async => true,
      sessionsResponse: _json({'live': [], 'saved': []}),
    );
    const message = 'HTTP OK, WebSocket not verified (no live session).';
    expect(find.text(message), findsOneWidget);
    expect(renderedColor(tester, message), themeTokens(tester).warn);
    expect(renderedColor(tester, message), isNot(themeTokens(tester).ok));
  });
}
