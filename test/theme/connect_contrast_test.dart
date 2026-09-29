// Connect-screen legibility: the review flagged that hint text, unfocused
// field borders and the outlined 'Test connection' button were unreadably
// low-contrast on the dark presets. These tests compute real WCAG contrast
// ratios against the surface each element sits on:
//   - hint text (ink3 on field)        >= 4.5:1
//   - unfocused input border (lineStrong on field) >= 3:1
//   - outlined button side (lineStrong on bg)      >= 3:1
// for EVERY preset.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/theme/presets.dart';

double _channelFrac(int v) {
  final c = v / 255.0;
  return c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(int argb) {
  final r = (argb >> 16) & 0xff;
  final g = (argb >> 8) & 0xff;
  final b = argb & 0xff;
  return 0.2126 * _channelFrac(r) +
      0.7152 * _channelFrac(g) +
      0.0722 * _channelFrac(b);
}

double contrast(int a, int b) {
  var la = _luminance(a);
  var lb = _luminance(b);
  if (la < lb) {
    final t = la;
    la = lb;
    lb = t;
  }
  return (la + 0.05) / (lb + 0.05);
}

void main() {
  for (final preset in OmpPreset.values) {
    group('preset ${preset.name}', () {
      final t = OmpTheme.tokens(preset);

      test('hint text is readable on the field (>= 4.5:1)', () {
        final ratio = contrast(t.ink3.toARGB32(), t.field.toARGB32());
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: '${preset.name}: hint ink3 on field is $ratio',
        );
      });

      test('unfocused input border is visible on the field (>= 3:1)', () {
        final themeData = OmpTheme.data(preset);
        final side =
            themeData.inputDecorationTheme.enabledBorder!.borderSide.color;
        final ratio = contrast(side.toARGB32(), t.field.toARGB32());
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason: '${preset.name}: enabled border on field is $ratio',
        );
      });

      test('outlined button outline is visible on the background (>= 3:1)', () {
        final themeData = OmpTheme.data(preset);
        final side = themeData.outlinedButtonTheme.style!.side!.resolve({})!;
        final ratio = contrast(side.color.toARGB32(), t.bg.toARGB32());
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason: '${preset.name}: outlined button side on bg is $ratio',
        );
      });
    });
  }
}
