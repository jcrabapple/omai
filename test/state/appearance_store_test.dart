// Appearance store tests: defaults, sanitizing bad and unknown JSON,
// persistence round-trip through an in-memory ReviewedKv, a write landing
// before the slow initial load finishes, and reset.

import 'dart:convert';

import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/state/appearance_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/theme/presets.dart';

class MemoryKv implements ReviewedKv {
  final Map<String, String> map = {};
  final Duration delay;
  MemoryKv({this.delay = Duration.zero});
  @override
  Future<String?> get(String key) async {
    await Future<void>.delayed(delay);
    return map[key];
  }

  @override
  Future<void> set(String key, String value) async {
    await Future<void>.delayed(delay);
    map[key] = value;
  }
}

void main() {
  test('defaults: terminal, followSystem on, no accent, comfortable, 1.0', () {
    const s = AppearanceSettings();
    expect(s.preset, OmpPreset.terminal);
    expect(s.followSystem, isTrue);
    expect(s.accentHex, isNull);
    expect(s.density, AppearanceDensity.comfortable);
    expect(s.textScale, 1.0);
  });

  test('sanitize: unknown values and bad JSON fall back to defaults', () {
    final s = AppearanceSettings.sanitize({
      'theme': 'neon',
      'followSystem': 'yes',
      'accent': 'not-hex',
      'density': 'cosy',
      'textScale': 2.5,
    });
    expect(s, AppearanceSettings.sanitize(const {}));

    expect(AppearanceSettings.decode('{not json'), const AppearanceSettings());
    expect(AppearanceSettings.decode(null), const AppearanceSettings());
    expect(AppearanceSettings.decode('42'), const AppearanceSettings());
  });

  test('sanitize accepts known values, including paper as a fixed choice', () {
    final s = AppearanceSettings.sanitize({
      'theme': 'paper',
      'followSystem': true,
      'accent': '#f472b6',
      'density': 'compact',
      'textScale': 1.15,
    });
    expect(s.preset, OmpPreset.paper);
    expect(s.followSystem, isTrue);
    expect(s.accentHex, '#f472b6');
    expect(s.density, AppearanceDensity.compact);
    expect(s.textScale, 1.15);
  });

  test('textScale accepts any num and falls back on other shapes', () {
    // An int 1 from JSON means the allowed 1.0.
    expect(
      AppearanceSettings.sanitize({'textScale': 1}).textScale,
      1.0,
    );
    // A string is not a number: the default.
    expect(
      AppearanceSettings.sanitize({'textScale': 'big'}).textScale,
      1.0,
    );
  });

  test('decode falls back to defaults on any decode or shape error', () {
    // A JSON number where a string is expected: TypeError, not a throw.
    expect(
      AppearanceSettings.decode('{"theme": 5}'),
      const AppearanceSettings(),
    );
    expect(
      AppearanceSettings.decode('{"density": 5}'),
      const AppearanceSettings(),
    );
    expect(
      AppearanceSettings.decode('{"preset": 5, "theme": 5}'),
      const AppearanceSettings(),
    );
    expect(AppearanceSettings.decode('{not json'), const AppearanceSettings());
  });

  test('effectivePreset ports the web effectiveTheme getter', () {
    const follow = AppearanceSettings();
    expect(follow.effectivePreset(Brightness.light), OmpPreset.paper);
    expect(follow.effectivePreset(Brightness.dark), OmpPreset.terminal);
    final followPaper = follow.copyWith(preset: OmpPreset.paper);
    // A paper choice still gets a dark theme on the dark side.
    expect(followPaper.effectivePreset(Brightness.dark), OmpPreset.terminal);
    final noFollow = follow.copyWith(followSystem: false, preset: OmpPreset.paper);
    expect(noFollow.effectivePreset(Brightness.dark), OmpPreset.paper);
    expect(noFollow.effectivePreset(Brightness.light), OmpPreset.paper);
  });

  group('store', () {
    test('persistence round-trip through an in-memory ReviewedKv', () async {
      final kv = MemoryKv();
      final container = ProviderContainer(
        overrides: [reviewedKvProvider.overrideWithValue(kv)],
      );
      addTearDown(container.dispose);

      await container
          .read(appearanceProvider.notifier)
          .setPreset(OmpPreset.graphite);
      await container
          .read(appearanceProvider.notifier)
          .setAccent('#f472b6');

      // A fresh container loads what the first one persisted.
      final container2 = ProviderContainer(
        overrides: [reviewedKvProvider.overrideWithValue(kv)],
      );
      addTearDown(container2.dispose);
      // First read initializes the store and starts the load.
      expect(container2.read(appearanceProvider).preset, OmpPreset.terminal);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final s = container2.read(appearanceProvider);
      expect(s.preset, OmpPreset.graphite);
      expect(s.accentHex, '#f472b6');
    });

    test('a write before the slow initial load finishes wins', () async {
      final kv = MemoryKv(delay: const Duration(milliseconds: 50));
      kv.map[appearanceKvKey] = jsonEncode({'theme': 'contrast'});
      final container = ProviderContainer(
        overrides: [reviewedKvProvider.overrideWithValue(kv)],
      );
      addTearDown(container.dispose);

      // The user acts before the load resolves.
      await container
          .read(appearanceProvider.notifier)
          .setPreset(OmpPreset.graphite);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(container.read(appearanceProvider).preset, OmpPreset.graphite);
      // And the write persisted over the old snapshot.
      expect(kv.map[appearanceKvKey], contains('graphite'));
    });

    test('reset returns to defaults and clears the persisted value', () async {
      final kv = MemoryKv();
      final container = ProviderContainer(
        overrides: [reviewedKvProvider.overrideWithValue(kv)],
      );
      addTearDown(container.dispose);

      final store = container.read(appearanceProvider.notifier);
      await store.setDensity(AppearanceDensity.compact);
      await store.setTextScale(1.3);
      expect(container.read(appearanceProvider).density,
          AppearanceDensity.compact);
      await store.reset();
      final s = container.read(appearanceProvider);
      expect(s, const AppearanceSettings());
      expect(kv.map[appearanceKvKey], contains('"density":"comfortable"'));
    });
  });
}
