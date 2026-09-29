// Ported from web/src/lib/render/__tests__/ansi.test.ts: the HTML assertions
// become span/style assertions with the same inputs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/render/ansi.dart';
import 'package:ohmypi/theme/presets.dart';

const e = '\x1b[';

final tokens = OmpTheme.tokens(OmpPreset.terminal);
final palette = ansiPalette(tokens);

bool hasBold(TextStyle? s) => s?.fontWeight == FontWeight.w700;
bool hasItalic(TextStyle? s) => s?.fontStyle == FontStyle.italic;
bool hasUnderline(TextStyle? s) => s?.decoration == TextDecoration.underline;
bool hasDim(TextStyle? s) => s?.fontWeight == FontWeight.w300;

Color? fgColor(TextSpan span) => span.style?.color;

List<TextSpan> spansOf(String input) => ansiToSpans(input, palette: palette);

String textOf(String input) => spansOf(input).map((s) => s.text ?? '').join();

void main() {
  group('ansiToSpans', () {
    test('passes plain text through', () {
      expect(textOf('a < b & "c"'), 'a < b & "c"');
      expect(textOf(''), '');
    });

    test('renders bold, dim, italic and underline', () {
      expect(hasBold(spansOf('${e}1mB${e}0m').single.style), isTrue);
      expect(hasItalic(spansOf('${e}3mI${e}23m').single.style), isTrue);
      expect(hasUnderline(spansOf('${e}4mU${e}24m').single.style), isTrue);
      final all = spansOf('${e}1;3;4mall').single.style!;
      expect(hasBold(all) && hasItalic(all) && hasUnderline(all), isTrue);
    });

    test('maps 30-37 and 90-97 to the 16 token colors', () {
      expect(fgColor(spansOf('${e}31mr${e}39m').single), palette[1]);
      expect(fgColor(spansOf('${e}37mw').single), palette[7]);
      expect(fgColor(spansOf('${e}90mg').single), palette[8]);
      expect(fgColor(spansOf('${e}97mb').single), palette[15]);
    });

    test('39 resets the color but keeps other attributes', () {
      final spans = spansOf('${e}1;32mA${e}39mB${e}0mC');
      expect(spans[0].text, 'A');
      expect(fgColor(spans[0]), palette[2]);
      expect(hasBold(spans[0].style), isTrue);
      expect(spans[1].text, 'B');
      expect(fgColor(spans[1]), isNull);
      expect(hasBold(spans[1].style), isTrue);
      expect(spans[2].text, 'C');
      expect(spans[2].style!.fontWeight, isNull);
    });

    test('supports 256 colors: palette, cube and gray ramp', () {
      expect(fgColor(spansOf('${e}38;5;9mx').single), palette[9]);
      expect(fgColor(spansOf('${e}38;5;196mx').single),
          const Color(0xffff0000));
      expect(fgColor(spansOf('${e}38;5;21mx').single),
          const Color(0xff0000ff));
      expect(fgColor(spansOf('${e}38;5;243mx').single),
          const Color(0xff767676));
      expect(fgColor(spansOf('${e}38;5;232mx').single),
          const Color(0xff080808));
    });

    test('supports truecolor and clamps out-of-range values', () {
      expect(fgColor(spansOf('${e}38;2;255;128;0mx').single),
          const Color(0xffff8000));
      expect(fgColor(spansOf('${e}38;2;999;-5;7mx').single),
          const Color(0xffff0007));
    });

    test('ignores an invalid 256 index', () {
      expect(textOf('${e}38;5;300mx'), 'x');
      expect(fgColor(spansOf('${e}38;5;300mx').single), isNull);
    });

    test('accepts colon separators and an empty parameter as reset', () {
      expect(fgColor(spansOf('${e}38:5:9mx${e}mY').first), palette[9]);
      expect(textOf('${e}38:5:9mx${e}mY'), 'xY');
    });

    test('applies the sequence from the fixture style (nested resets)', () {
      final s = '[${e}38;5;243m░░${e}39m${e}1m${e}38;5;39m██${e}22m${e}39m]';
      final spans = spansOf(s);
      expect(textOf(s), '[░░██]');
      expect(fgColor(spans[1]), const Color(0xff767676));
      expect(fgColor(spans[2]), const Color(0xff00afff));
      expect(hasBold(spans[2].style), isTrue);
    });

    test('keeps newlines and tabs, drops carriage returns and other controls',
        () {
      expect(textOf('a\r\nb\tc\rd\x00e\x07f'), 'a\nb\tcdef');
    });

    test('drops background colors, inverse and other unsupported attributes',
        () {
      final out = textOf('${e}41mred bg${e}0m ${e}7minv${e}27m ${e}48;5;9mx');
      expect(out, 'red bg inv x');
      expect(fgColor(spansOf('${e}41mred bg${e}0m').single), isNull);
    });

    test('strips cursor movement, erase and private-mode sequences', () {
      final seq = 'a${e}2K'
          '${e}1;1H'
          '$e?25l'
          '${e}3Ab';
      expect(textOf(seq), 'ab');
    });

    test('strips OSC sequences including hyperlinks and titles', () {
      expect(textOf('a\x1b]0;title\x07b'), 'ab');
      expect(textOf('\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\'),
          'link');
    });

    test('does not leak escape bytes', () {
      final out = textOf('x${e}31m y ${e}0m z\x1bM');
      expect(out.contains('\x1b'), isFalse);
    });
  });

  group('stripAnsi', () {
    test('removes every sequence', () {
      expect(stripAnsi('${e}1;31mred${e}0m \x1b]0;t\x07ok'), 'red ok');
    });
  });

  group('ansiPalette', () {
    test('status hues come from tokens for every preset', () {
      for (final preset in OmpPreset.values) {
        final t = OmpTheme.tokens(preset);
        final pal = ansiPalette(t);
        expect(pal, hasLength(16));
        expect(pal[1], t.err);
        expect(pal[2], t.ok);
        expect(pal[3], t.warn);
        expect(pal[4], t.accent);
        expect(pal[7], t.ink);
      }
    });
  });
}
