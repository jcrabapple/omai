// Appearance page widget tests: tapping a preset card updates the store and
// marks the card selected (semantics), accent swatch selection updates the
// store, and the low-contrast warning appears for a dark-on-light accent
// (green on paper). Follow-system switch toggles the store too.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/features/settings/appearance_page.dart';
import 'package:ohmypi/state/appearance_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'dart:ui' show SemanticsFlag;

import 'package:ohmypi/theme/presets.dart';

import 'fakes.dart';

class FixedAppearance extends AppearanceStore {
  FixedAppearance(this.initial);
  final AppearanceSettings initial;
  @override
  AppearanceSettings build() => initial;
}

Future<ProviderContainer> pump(
  WidgetTester tester, {
  AppearanceSettings initial = const AppearanceSettings(),
  TextScaler? textScaler,
}) async {
  final kv = MemoryKv();
  final container = ProviderContainer(overrides: [
    reviewedKvProvider.overrideWithValue(kv),
    appearanceProvider.overrideWith(() => FixedAppearance(initial)),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: Builder(
          builder: (context) => textScaler == null
              ? const AppearancePage()
              : MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: textScaler),
                  child: const AppearancePage(),
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('no RenderFlex overflow at narrow width with large text', (
    tester,
  ) async {
    // 2.0 system text scale x 1.3 app text scale, 360dp wide.
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      initial: const AppearanceSettings(textScale: 1.3),
      textScaler: const TextScaler.linear(2.0 * 1.3),
    );
    // Every section must lay out, including the density and text size
    // segmented controls.
    await tester.ensureVisible(find.text('Larger'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'no RenderFlex overflow for the segmented controls');
  });

  testWidgets('tapping a preset card updates the store and the semantics',
      (tester) async {
    final container = await pump(tester);
    expect(container.read(appearanceProvider).preset, OmpPreset.terminal);

    await tester.tap(find.byKey(const ValueKey('appearance-preset-graphite')));
    await tester.pumpAndSettle();
    expect(container.read(appearanceProvider).preset, OmpPreset.graphite);

    // The selected card advertises checked in a mutually exclusive group.
    final graphite = tester.getSemantics(
      find.byKey(const ValueKey('appearance-preset-graphite')),
    );
    expect(
      // ignore: deprecated_member_use
      graphite.hasFlag(SemanticsFlag.isChecked),
      isTrue,
    );
    final terminal = tester.getSemantics(
      find.byKey(const ValueKey('appearance-preset-terminal')),
    );
    expect(
      // ignore: deprecated_member_use
      terminal.hasFlag(SemanticsFlag.isChecked),
      isFalse,
    );
  });

  testWidgets('tapping an accent swatch updates the store', (tester) async {
    final container = await pump(tester);
    await tester.ensureVisible(
        find.byKey(const ValueKey('appearance-accent-pink')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-accent-pink')));
    await tester.pumpAndSettle();
    expect(container.read(appearanceProvider).accentHex, '#f472b6');

    // Theme default clears it again.
    await tester.ensureVisible(
        find.byKey(const ValueKey('appearance-accent-default')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-accent-default')));
    await tester.pumpAndSettle();
    expect(container.read(appearanceProvider).accentHex, isNull);
  });

  testWidgets('follow system switch writes the store', (tester) async {
    final container = await pump(tester);
    await tester.ensureVisible(
        find.byKey(const ValueKey('appearance-follow-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-follow-system')));
    await tester.pumpAndSettle();
    expect(container.read(appearanceProvider).followSystem, isFalse);
  });

  testWidgets('a low-contrast accent on the light side shows the warning',
      (tester) async {
    // Default is followSystem on; the test surface is light, so the green
    // accent sits on paper and fails the 3:1 check.
    final container = await pump(tester);
    await tester.ensureVisible(
        find.byKey(const ValueKey('appearance-accent-green')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-accent-green')));
    await tester.pumpAndSettle();
    expect(container.read(appearanceProvider).accentHex, '#4ade80');
    expect(
      find.byKey(const ValueKey('appearance-accent-low-contrast')),
      findsOneWidget,
    );
  });

  testWidgets('reset restores the defaults', (tester) async {
    final container = await pump(
      tester,
      initial: const AppearanceSettings(preset: OmpPreset.contrast),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('appearance-reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-reset')));
    await tester.pumpAndSettle();
    expect(container.read(appearanceProvider), const AppearanceSettings());
  });
}
