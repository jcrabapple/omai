import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:omai/app/app.dart';
import 'package:omai/features/sessions/sessions_screen.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/sessions_store.dart';

class MockConnectionPrefs extends Mock implements ConnectionPrefs {}

class MockTokenStore extends Mock implements TokenStore {}

class _MemoryKv implements ReviewedKv {
  final Map<String, String> _map = {};

  @override
  Future<String?> get(String key) async => _map[key];

  @override
  Future<void> set(String key, String value) async => _map[key] = value;
}

void main() {
  late MockConnectionPrefs prefs;
  late MockTokenStore tokens;

  setUp(() {
    prefs = MockConnectionPrefs();
    tokens = MockTokenStore();
    when(() => prefs.load()).thenAnswer((_) async => const []);
    when(() => prefs.save(any())).thenAnswer((_) async {});
    when(() => tokens.read(any())).thenAnswer((_) async => null);
    when(() => tokens.write(any(), any())).thenAnswer((_) async {});
    when(() => tokens.delete(any())).thenAnswer((_) async {});
  });

  Widget wrap() => ProviderScope(
        overrides: [
          connectionPrefsProvider.overrideWithValue(prefs),
          tokenStoreProvider.overrideWithValue(tokens),
          // The signed-in shell starts polling and reads the reviewed store;
          // neither can touch real plugin channels in a widget test.
          sessionsPollIntervalProvider
              .overrideWithValue(const Duration(hours: 1)),
          reviewedKvProvider.overrideWithValue(_MemoryKv()),
        ],
        child: const OmpApp(),
      );

  testWidgets('signed out shows the Connect screen', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('Connect to a gateway'), findsOneWidget);
    expect(find.text('Gateway URL'), findsOneWidget);
    expect(find.text('Gateway token'), findsOneWidget);
    expect(find.byType(SessionsScreen), findsNothing);
  });

  testWidgets('sign in switches to the home shell', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'https://gw.example.com');
    // The token field sits under the label text; find it by index instead.
    await tester.enterText(find.byType(TextField).at(1), 'tok');
    await tester.tap(find.text('Sign in'));
    // The signed-in shell shows a skeleton spinner while the first sessions
    // fetch is in flight, so a fixed pump instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SessionsScreen), findsOneWidget);
  });
}
