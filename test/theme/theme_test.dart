import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/theme/presets.dart';
import 'package:omai/theme/tokens.dart';

void main() {
  group('presets', () {
    test('every preset defines a complete token set', () {
      for (final preset in OmpPreset.values) {
        final t = OmpTheme.tokens(preset);
        expect(t.bg, isNot(Colors.transparent), reason: '${preset.name}.bg');
        expect(t.canvas, isNot(Colors.transparent), reason: '${preset.name}.canvas');
        expect(t.surface, isNot(Colors.transparent), reason: '${preset.name}.surface');
        expect(t.inset, isNot(Colors.transparent), reason: '${preset.name}.inset');
        expect(t.field, isNot(Colors.transparent), reason: '${preset.name}.field');
        for (final c in [t.ink, t.ink2, t.ink3, t.line, t.lineStrong]) {
          expect((c.a * 255.0).round(), 255, reason: preset.name);
        }
        expect(t.accentInk, isNot(t.accent),
            reason: '${preset.name}: accent-ink must contrast the accent');
      }
    });

    test('light/dark classification matches themes.css color-scheme', () {
      expect(OmpPreset.paper.isLight, isTrue);
      expect(OmpPreset.terminal.isLight, isFalse);
      expect(OmpPreset.graphite.isLight, isFalse);
      expect(OmpPreset.contrast.isLight, isFalse);
    });

    test('ported hex values match themes.css', () {
      final terminal = OmpTheme.tokens(OmpPreset.terminal);
      expect(terminal.bg, const Color(0xFF0a0d0b));
      expect(terminal.accent, const Color(0xFF4ade80));
      expect(terminal.accentInk, const Color(0xFF04140a));

      final graphite = OmpTheme.tokens(OmpPreset.graphite);
      expect(graphite.accent, const Color(0xFF60a5fa));

      final paper = OmpTheme.tokens(OmpPreset.paper);
      expect(paper.bg, const Color(0xFFf3f1ec));
      expect(paper.accent, const Color(0xFF1f7a4d));
      expect(paper.err, const Color(0xFFb42318));

      final contrast = OmpTheme.tokens(OmpPreset.contrast);
      expect(contrast.bg, const Color(0xFF000000));
      expect(contrast.accent, const Color(0xFFffd60a));
      expect(contrast.lineStrong, const Color(0xFFFFFFFF));
    });

    test('accent override replaces accent but keeps the rest', () {
      final t = OmpTheme.tokens(OmpPreset.terminal,
          accent: const Color(0xFF123456));
      expect(t.accent, const Color(0xFF123456));
      expect(t.bg, const Color(0xFF0a0d0b));
    });

    test('fromName falls back to terminal on unknown names', () {
      expect(OmpPreset.fromName('paper'), OmpPreset.paper);
      expect(OmpPreset.fromName('nope'), OmpPreset.terminal);
      expect(OmpPreset.fromName(null), OmpPreset.terminal);
    });
  });

  group('tokens extension', () {
    test('lerp mixes colors', () {
      final a = OmpTheme.tokens(OmpPreset.terminal);
      final b = OmpTheme.tokens(OmpPreset.paper);
      final mid = a.lerp(b, 0.5) as dynamic;
      expect(mid.bg, Color.lerp(a.bg, b.bg, 0.5));
    });

    test('soft colors are ink/accent mixes over transparent', () {
      final t = OmpTheme.tokens(OmpPreset.paper);
      expect(t.accentSoft, Color.lerp(t.accent, Colors.transparent, 0.86));
      expect(t.hover, Color.lerp(t.ink, Colors.transparent, 0.94));
    });

    test('ThemeData carries OmpTokens and a scheme per preset', () {
      for (final preset in OmpPreset.values) {
        final data = OmpTheme.data(preset);
        expect(data.extension<OmpTokens>(), isNotNull, reason: preset.name);
        expect(data.colorScheme.brightness,
            OmpTheme.tokens(preset).brightness, reason: preset.name);
      }
    });
  });
}
