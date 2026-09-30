// App theme selection tests: followSystem on/off x preset x platform
// brightness picks the right preset and brightness; the accent override
// reaches ThemeData; the text-size setting multiplies the system text scaler
// instead of replacing it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/app/app.dart';
import 'package:omai/state/appearance_store.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/theme/presets.dart';
import 'package:omai/theme/tokens.dart';

import 'fakes.dart';

class FixedAppearance extends AppearanceStore {
  FixedAppearance(this.initial);
  final AppearanceSettings initial;
  @override
  AppearanceSettings build() => initial;
}

ProviderContainer containerWith(AppearanceSettings settings) {
  final c = ProviderContainer(overrides: [
    reviewedKvProvider.overrideWithValue(MemoryKv()),
    connectionPrefsProvider.overrideWithValue(MemoryPrefs(const [])),
    tokenStoreProvider.overrideWithValue(const FixedTokenStore()),
    appearanceProvider.overrideWith(() => FixedAppearance(settings)),
  ]);
  addTearDown(c.dispose);
  return c;
}

/// Pumps the app and captures the resolved theme + text scaler at the home
/// leaf of the tree.
Future<(OmpTokens, TextScaler)> pump(
  WidgetTester tester,
  AppearanceSettings settings,
) async {
  OmpTokens? tokens;
  TextScaler? scaler;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: containerWith(settings),
      child: const OmpApp(),
    ),
  );
  // Read from the rendered home via a visitor after a frame.
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(Navigator).first);
  widgetsBindingRead(context, (t, s) {
    tokens = t;
    scaler = s;
  });
  return (tokens!, scaler!);
}

void widgetsBindingRead(
  BuildContext context,
  void Function(OmpTokens, TextScaler) record,
) {
  // MaterialApp's theme is observable from any descendant; the Navigator's
  // context sits below MaterialApp so Theme.of works.
  record(
    Theme.of(context).extension<OmpTokens>()!,
    MediaQuery.textScalerOf(context),
  );
}

void main() {
  testWidgets('follow system: light device shows paper, dark shows the preset',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    final (light, _) = await pump(
      tester,
      const AppearanceSettings(preset: OmpPreset.graphite),
    );
    expect(light.brightness, Brightness.light);
    expect(light.bg, OmpTheme.tokens(OmpPreset.paper).bg);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    final (dark, _) = await pump(
      tester,
      const AppearanceSettings(preset: OmpPreset.graphite),
    );
    expect(dark.brightness, Brightness.dark);
    expect(dark.bg, OmpTheme.tokens(OmpPreset.graphite).bg);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  });

  testWidgets('follow system with a paper choice still gets a dark theme',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    final (dark, _) = await pump(
      tester,
      const AppearanceSettings(preset: OmpPreset.paper),
    );
    expect(dark.bg, OmpTheme.tokens(OmpPreset.terminal).bg);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  });

  testWidgets('follow system off fixes the mode to the chosen preset',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    final (light, _) = await pump(
      tester,
      const AppearanceSettings(preset: OmpPreset.paper, followSystem: false),
    );
    expect(light.brightness, Brightness.light);
    expect(light.bg, OmpTheme.tokens(OmpPreset.paper).bg);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  });

  testWidgets('accent override reaches ThemeData', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    final (dark, _) = await pump(
      tester,
      const AppearanceSettings(preset: OmpPreset.graphite, accentHex: '#f472b6'),
    );
    expect(dark.accent, const Color(0xFFF472B6));
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  });

  testWidgets('text size multiplies the system scaler', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    tester.platformDispatcher.textScaleFactorTestValue = 1.0;
    final (_, base) = await pump(
      tester,
      const AppearanceSettings(textScale: 1.15),
    );
    expect(base.scale(100), closeTo(115, 0.01));

    // A system font scale still applies underneath.
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Navigator).first);
    expect(
      MediaQuery.textScalerOf(context).scale(100),
      closeTo(230, 0.01),
    );
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  });
}
