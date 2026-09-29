import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ohmypi/app/app.dart';
import 'package:ohmypi/features/home/home_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';

class MockConnectionPrefs extends Mock implements ConnectionPrefs {}

class MockTokenStore extends Mock implements TokenStore {}

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
        ],
        child: const OmpApp(),
      );

  testWidgets('signed out shows the Connect screen', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('Connect to ohmypi'), findsOneWidget);
    expect(find.text('Gateway URL'), findsOneWidget);
    expect(find.text('Gateway token'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('sign in switches to the home shell', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'https://gw.example.com');
    // The token field sits under the label text; find it by index instead.
    await tester.enterText(find.byType(TextField).at(1), 'tok');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
