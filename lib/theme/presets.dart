// Theme presets ported from web/src/styles/themes.css:
// terminal, graphite (dark) and paper (light), contrast (dark).

import 'package:flutter/material.dart';

import 'tokens.dart';

/// The four presets, named after their `data-theme` values.
enum OmpPreset {
  terminal('terminal'),
  graphite('graphite'),
  paper('paper'),
  contrast('contrast');

  const OmpPreset(this.name);
  final String name;

  static OmpPreset fromName(String? name) => OmpPreset.values
      .firstWhere((p) => p.name == name, orElse: () => OmpPreset.terminal);

  bool get isLight => this == OmpPreset.paper;
}

class OmpTheme {
  const OmpTheme._();

  /// The full token set for a preset, with an optional custom accent
  /// (settings override). `accentInk` stays the preset's unless overridden.
  static OmpTokens tokens(OmpPreset preset, {Color? accent, Color? accentInk}) {
    final base = switch (preset) {
      OmpPreset.terminal => const OmpTokens(
          brightness: Brightness.dark,
          bg: Color(0xFF0a0d0b),
          canvas: Color(0xFF0e1210),
          surface: Color(0xFF141a17),
          inset: Color(0xFF0b0f0d),
          field: Color(0xFF101512),
          ink: Color(0xFFd7e3da),
          ink2: Color(0xFF93a599),
          ink3: Color(0xFF798a7f),
          line: Color(0xFF1e2823),
          lineStrong: Color(0xFF2c3a33),
          accent: Color(0xFF4ade80),
          accentInk: Color(0xFF04140a),
          ok: Color(0xFF4ade80),
          warn: Color(0xFFf5b942),
          err: Color(0xFFf87171),
          scrim: Color(0x9E000000),
        ),
      OmpPreset.graphite => const OmpTokens(
          brightness: Brightness.dark,
          bg: Color(0xFF0f1114),
          canvas: Color(0xFF14171b),
          surface: Color(0xFF1a1e23),
          inset: Color(0xFF101317),
          field: Color(0xFF15181d),
          ink: Color(0xFFe2e6ea),
          ink2: Color(0xFF9aa3ad),
          ink3: Color(0xFF838b95),
          line: Color(0xFF242a31),
          lineStrong: Color(0xFF343c46),
          accent: Color(0xFF60a5fa),
          accentInk: Color(0xFF06121f),
          ok: Color(0xFF4ade80),
          warn: Color(0xFFf5b942),
          err: Color(0xFFf87171),
          scrim: Color(0x9E000000),
        ),
      OmpPreset.paper => const OmpTokens(
          brightness: Brightness.light,
          bg: Color(0xFFf3f1ec),
          canvas: Color(0xFFfaf9f6),
          surface: Color(0xFFFFFFFF),
          inset: Color(0xFFefede7),
          field: Color(0xFFFFFFFF),
          ink: Color(0xFF1d1f1c),
          ink2: Color(0xFF555a52),
          ink3: Color(0xFF656961),
          line: Color(0xFFe3e0d8),
          lineStrong: Color(0xFFcfcbc0),
          accent: Color(0xFF1f7a4d),
          accentInk: Color(0xFFFFFFFF),
          ok: Color(0xFF1f7a4d),
          warn: Color(0xFFa15c00),
          err: Color(0xFFb42318),
          scrim: Color(0x5914140f),
        ),
      OmpPreset.contrast => const OmpTokens(
          brightness: Brightness.dark,
          bg: Color(0xFF000000),
          canvas: Color(0xFF000000),
          surface: Color(0xFF0d0d0d),
          inset: Color(0xFF000000),
          field: Color(0xFF000000),
          ink: Color(0xFFFFFFFF),
          ink2: Color(0xFFdcdcdc),
          ink3: Color(0xFFb0b0b0),
          line: Color(0xFF6b6b6b),
          lineStrong: Color(0xFFFFFFFF),
          accent: Color(0xFFffd60a),
          accentInk: Color(0xFF000000),
          ok: Color(0xFF5cff8a),
          warn: Color(0xFFffd60a),
          err: Color(0xFFff6b6b),
          scrim: Color(0xBF000000),
        ),
    };
    if (accent == null) return base;
    return base.copyWith(accent: accent, accentInk: accentInk);
  }

  /// Material 3 [ColorScheme] mapped from the preset tokens.
  static ColorScheme scheme(OmpTokens t) {
    return ColorScheme(
      brightness: t.brightness,
      primary: t.accent,
      onPrimary: t.accentInk,
      secondary: t.ink2,
      onSecondary: t.bg,
      error: t.err,
      onError: t.bg,
      surface: t.canvas,
      onSurface: t.ink,
      surfaceContainerHighest: t.surface,
      onSurfaceVariant: t.ink2,
      outline: t.lineStrong,
      outlineVariant: t.line,
      inverseSurface: t.ink,
      onInverseSurface: t.bg,
    );
  }

  /// Material [ThemeData] for a preset, tokens attached as a [ThemeExtension].
  static ThemeData data(OmpPreset preset, {Color? accent}) {
    final t = tokens(preset, accent: accent);
    final scheme = OmpTheme.scheme(t);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      splashFactory: InkSplash.splashFactory,
      extensions: [t],
      dividerColor: t.line,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.field,
        hintStyle: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsBase),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: OmpMetrics.s3, vertical: OmpMetrics.s3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
          borderSide: BorderSide(color: t.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
          borderSide: BorderSide(color: t.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
          borderSide: BorderSide(color: t.accent, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.accentInk,
          minimumSize: const Size(64, OmpMetrics.hit),
          textStyle: const TextStyle(fontSize: OmpMetrics.fsBase, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.ink,
          side: BorderSide(color: t.lineStrong),
          minimumSize: const Size(64, OmpMetrics.hit),
          textStyle: const TextStyle(fontSize: OmpMetrics.fsBase),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: OmpMetrics.fsBase, height: 1.55),
        bodySmall: TextStyle(fontSize: OmpMetrics.fsSm, height: 1.55),
        labelSmall: TextStyle(fontSize: OmpMetrics.fsXs),
        titleLarge: TextStyle(fontSize: OmpMetrics.fsXl, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(fontSize: OmpMetrics.fsLg, fontWeight: FontWeight.w600),
      ).apply(bodyColor: t.ink, displayColor: t.ink),
      fontFamily: 'Roboto',
    );
  }
}
