// Appearance settings, ported from web/src/lib/state/settings.svelte.ts
// (sanitizeSettings, DEFAULTS, effectiveTheme) and the accent palette from
// web/src/lib/state/accents.ts. Persisted device-locally as JSON under
// 'ompgw-appearance' through the ReviewedKv seam, sanitized on load: unknown
// enum values and malformed JSON fall back to the defaults. Writes made
// before the (async) initial load finishes win over it, the same _dirty
// pattern hidden_cwds.dart uses. The app wires these values into
// MaterialApp (theme/darkTheme/themeMode/builder) in app.dart.

import 'dart:convert';

import 'package:flutter/material.dart' show Brightness, VisualDensity;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/presets.dart';
import 'reviewed_store.dart';

/// The persisted appearance key.
const appearanceKvKey = 'ompgw-appearance';

/// Text scale factors, labelled Small / Default / Large / Larger.
const appearanceTextScales = <double>[0.9, 1.0, 1.15, 1.3];

/// Density choices for the segmented control.
enum AppearanceDensity { comfortable, compact }

extension AppearanceDensityX on AppearanceDensity {
  String get name => this == AppearanceDensity.comfortable ? 'comfortable' : 'compact';
  VisualDensity get visualDensity =>
      this == AppearanceDensity.comfortable
          ? VisualDensity.standard
          : VisualDensity.compact;

  static AppearanceDensity fromName(String? name) =>
      name == 'compact' ? AppearanceDensity.compact : AppearanceDensity.comfortable;
}

/// Accent choices ported from web/src/lib/state/accents.ts. Hex strings so
/// the stored value matches the web one.
class AccentChoice {
  const AccentChoice(this.id, this.label, this.hex);
  final String id;
  final String label;
  final String hex;

  static const all = <AccentChoice>[
    AccentChoice('green', 'Green', '#4ade80'),
    AccentChoice('blue', 'Blue', '#60a5fa'),
    AccentChoice('violet', 'Violet', '#a78bfa'),
    AccentChoice('pink', 'Pink', '#f472b6'),
    AccentChoice('orange', 'Orange', '#fb923c'),
    AccentChoice('yellow', 'Yellow', '#facc15'),
    AccentChoice('teal', 'Teal', '#2dd4bf'),
    AccentChoice('red', 'Red', '#f87171'),
  ];

  /// Parses a stored hex like '#4ade80'; null when malformed (falls back to
  /// the theme default).
  static String? sanitizeHex(String? v) =>
      v != null && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v) ? v : null;
}

/// The persisted appearance settings. All fields sanitized on load.
class AppearanceSettings {
  const AppearanceSettings({
    this.preset = OmpPreset.terminal,
    this.followSystem = true,
    this.accentHex,
    this.density = AppearanceDensity.comfortable,
    this.textScale = 1.0,
  });

  /// The chosen theme. With followSystem on, a paper choice only shows on a
  /// light system; the dark side uses [OmpPreset.terminal] then.
  final OmpPreset preset;

  /// True (the app default today): paper when the device is light, the dark
  /// preset otherwise.
  final bool followSystem;

  /// Hex like '#22c55e', or null for the theme's own accent.
  final String? accentHex;

  final AppearanceDensity density;

  /// One of [appearanceTextScales]; multiplies the system text scaler.
  final double textScale;

  /// Theme after followSystem is applied, for a system [brightness]. Ported
  /// from the web effectiveTheme getter.
  OmpPreset effectivePreset(Brightness systemBrightness) {
    if (!followSystem) return preset;
    if (systemBrightness == Brightness.light) return OmpPreset.paper;
    return preset == OmpPreset.paper ? OmpPreset.terminal : preset;
  }

  Map<String, Object?> toJson() => {
    'theme': preset.name,
    'followSystem': followSystem,
    'accent': accentHex,
    'density': density.name,
    'textScale': textScale,
  };

  /// Unknown enum values and malformed hex fall back to defaults, ported
  /// from sanitizeSettings.
  static AppearanceSettings sanitize(Object? raw) {
    final m = raw is Map ? raw : const {};
    final theme = OmpPreset.fromName(m['theme'] as String?);
    return AppearanceSettings(
      preset: theme,
      // Unknown / missing falls back to the app default (true: the app
      // already follows the system today), not the web default.
      followSystem: m['followSystem'] is bool ? m['followSystem'] as bool : true,
      accentHex: AccentChoice.sanitizeHex(m['accent'] as String?),
      density: AppearanceDensityX.fromName(m['density'] as String?),
      textScale: appearanceTextScales.contains(m['textScale'])
          ? m['textScale'] as double
          : 1.0,
    );
  }

  /// Decodes a persisted JSON string; anything unparsable is the defaults.
  static AppearanceSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return const AppearanceSettings();
    try {
      return sanitize(jsonDecode(raw));
    } on FormatException {
      return const AppearanceSettings();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AppearanceSettings &&
      other.preset == preset &&
      other.followSystem == followSystem &&
      other.accentHex == accentHex &&
      other.density == density &&
      other.textScale == textScale;

  @override
  int get hashCode => Object.hash(preset, followSystem, accentHex, density, textScale);

  AppearanceSettings copyWith({
    OmpPreset? preset,
    bool? followSystem,
    String? accentHex,
    bool clearAccent = false,
    AppearanceDensity? density,
    double? textScale,
  }) {
    return AppearanceSettings(
      preset: preset ?? this.preset,
      followSystem: followSystem ?? this.followSystem,
      accentHex: clearAccent ? null : (accentHex ?? this.accentHex),
      density: density ?? this.density,
      textScale: textScale ?? this.textScale,
    );
  }
}

class AppearanceStore extends Notifier<AppearanceSettings> {
  bool _dirty = false;

  ReviewedKv get _kv => ref.read(reviewedKvProvider);

  @override
  AppearanceSettings build() {
    _dirty = false;
    _load();
    return const AppearanceSettings();
  }

  Future<void> _load() async {
    final raw = await _kv.get(appearanceKvKey);
    // The user already changed something before the slow load finished:
    // the write wins over the persisted snapshot.
    if (!ref.mounted || _dirty) return;
    state = AppearanceSettings.decode(raw);
  }

  Future<void> _write(AppearanceSettings next) async {
    _dirty = true;
    state = next;
    await _kv.set(appearanceKvKey, jsonEncode(next.toJson()));
  }

  Future<void> setPreset(OmpPreset p) => _write(state.copyWith(preset: p));
  Future<void> setFollowSystem(bool v) => _write(state.copyWith(followSystem: v));
  Future<void> setAccent(String? hex) =>
      hex == null
          ? _write(state.copyWith(clearAccent: true))
          : _write(state.copyWith(accentHex: hex));
  Future<void> setDensity(AppearanceDensity d) => _write(state.copyWith(density: d));
  Future<void> setTextScale(double s) => _write(state.copyWith(textScale: s));

  /// Back to the defaults and clear the persisted value.
  Future<void> reset() async {
    _dirty = true;
    state = const AppearanceSettings();
    await _kv.set(appearanceKvKey, jsonEncode(state.toJson()));
  }
}

final appearanceProvider =
    NotifierProvider<AppearanceStore, AppearanceSettings>(AppearanceStore.new);
