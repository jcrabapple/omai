// Design tokens ported from web/src/styles/tokens.css. Colors live in
// presets.dart (ported from themes.css). Widgets read tokens only.

import 'package:flutter/material.dart';

/// Numeric and structural tokens shared by every theme preset.
abstract final class OmpMetrics {
  /// Radii, from --r-lg / --r-md / --r-sm.
  static const double radiusLg = 10;
  static const double radiusMd = 8;
  static const double radiusSm = 6;

  /// Spacing scale, from --s-1 .. --s-7.
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double s7 = 48;

  /// Type scale, from --fs-xs .. --fs-xl (coarse pointer bumps base to 15).
  static const double fsXs = 11;
  static const double fsSm = 12;
  static const double fsBase = 14;
  static const double fsLg = 16;
  static const double fsXl = 20;

  /// Minimum touch target on coarse pointers (--hit: 44px).
  static const double hit = 44;
}

/// Per-preset color tokens, as a [ThemeExtension] so widgets reach them via
/// `Theme.of(context).extension<OmpTokens>()`.
@immutable
class OmpTokens extends ThemeExtension<OmpTokens> {
  const OmpTokens({
    required this.brightness,
    required this.bg,
    required this.canvas,
    required this.surface,
    required this.inset,
    required this.field,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.lineStrong,
    required this.accent,
    required this.accentInk,
    required this.ok,
    required this.warn,
    required this.err,
    required this.scrim,
  });

  final Brightness brightness;
  final Color bg;
  final Color canvas;
  final Color surface;
  final Color inset;
  final Color field;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color line;
  final Color lineStrong;
  final Color accent;

  /// Text color used on top of [accent].
  final Color accentInk;
  final Color ok;
  final Color warn;
  final Color err;

  /// Dialog scrims, from --scrim.
  final Color scrim;

  /// --hover / --press: ink mixed over transparent.
  Color get hover => Color.lerp(ink, Colors.transparent, 0.94)!;
  Color get press => Color.lerp(ink, Colors.transparent, 0.90)!;

  /// --accent-soft: accent mixed over transparent.
  Color get accentSoft => Color.lerp(accent, Colors.transparent, 0.86)!;
  Color get warnSoft => Color.lerp(warn, Colors.transparent, 0.86)!;
  Color get errSoft => Color.lerp(err, Colors.transparent, 0.88)!;

  @override
  OmpTokens copyWith({
    Brightness? brightness,
    Color? bg,
    Color? canvas,
    Color? surface,
    Color? inset,
    Color? field,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? line,
    Color? lineStrong,
    Color? accent,
    Color? accentInk,
    Color? ok,
    Color? warn,
    Color? err,
    Color? scrim,
  }) {
    return OmpTokens(
      brightness: brightness ?? this.brightness,
      bg: bg ?? this.bg,
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      inset: inset ?? this.inset,
      field: field ?? this.field,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      line: line ?? this.line,
      lineStrong: lineStrong ?? this.lineStrong,
      accent: accent ?? this.accent,
      accentInk: accentInk ?? this.accentInk,
      ok: ok ?? this.ok,
      warn: warn ?? this.warn,
      err: err ?? this.err,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  OmpTokens lerp(ThemeExtension<OmpTokens>? other, double t) {
    if (other is! OmpTokens) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return OmpTokens(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: mix(bg, other.bg),
      canvas: mix(canvas, other.canvas),
      surface: mix(surface, other.surface),
      inset: mix(inset, other.inset),
      field: mix(field, other.field),
      ink: mix(ink, other.ink),
      ink2: mix(ink2, other.ink2),
      ink3: mix(ink3, other.ink3),
      line: mix(line, other.line),
      lineStrong: mix(lineStrong, other.lineStrong),
      accent: mix(accent, other.accent),
      accentInk: mix(accentInk, other.accentInk),
      ok: mix(ok, other.ok),
      warn: mix(warn, other.warn),
      err: mix(err, other.err),
      scrim: mix(scrim, other.scrim),
    );
  }
}
