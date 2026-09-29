// ANSI SGR to TextSpans. Supported: reset, bold, dim, italic, underline, the
// 16 basic foreground colors (mapped onto theme tokens), 256 and truecolor
// foregrounds (inline colors built from clamped integers). Every other escape
// sequence and control character is dropped. Ported from
// web/src/lib/render/ansi.ts (ansiToHtml -> ansiToSpans; spans replace HTML).

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// CSI (params, intermediates, final byte), OSC (up to BEL or ST), other
/// two-byte escapes.
final RegExp _escapes =
    RegExp(r'\x1b(?:\[([ -?]*)([@-~])|\][^\x07\x1b]*(?:\x07|\x1b\\)?|[@-Z\\-_])');

/// \x00-\x08, \x0b-\x1f, \x7f (keeps \t and \n).
final RegExp _control = RegExp(r'[\x00-\x08\x0b-\x1f\x7f]');

class _Style {
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;

  /// 0-15 for the token palette, or a concrete [Color] for 256/truecolor.
  Object? fg; // int | Color | null
}

const List<int> _cube = [0, 95, 135, 175, 215, 255];

int _clamp(int n) => n < 0 ? 0 : (n > 255 ? 255 : n);

Color _rgb(int r, int g, int b) =>
    Color.fromARGB(255, _clamp(r), _clamp(g), _clamp(b));

/// 256-color to a palette index (<16) or a concrete color, else null.
Object? _color256(int n) {
  if (n < 0 || n > 255) return null;
  if (n < 16) return n;
  if (n < 232) {
    final i = n - 16;
    return _rgb(_cube[i ~/ 36], _cube[(i ~/ 6) % 6], _cube[i % 6]);
  }
  final v = 8 + (n - 232) * 10;
  return _rgb(v, v, v);
}

void _applySgr(_Style style, String raw) {
  final p = <int>[
    for (final x in (raw.isEmpty ? const <String>['0'] : raw.split(RegExp('[;:]'))))
      x.isEmpty ? 0 : (int.tryParse(x) ?? 0)
  ];
  for (var i = 0; i < p.length; i++) {
    final c = p[i];
    if (c == 0) {
      style
        ..bold = false
        ..dim = false
        ..italic = false
        ..underline = false
        ..fg = null;
    } else if (c == 1) {
      style.bold = true;
    } else if (c == 2) {
      style.dim = true;
    } else if (c == 3) {
      style.italic = true;
    } else if (c == 4) {
      style.underline = true;
    } else if (c == 22) {
      style
        ..bold = false
        ..dim = false;
    } else if (c == 23) {
      style.italic = false;
    } else if (c == 24) {
      style.underline = false;
    } else if (c >= 30 && c <= 37) {
      style.fg = c - 30;
    } else if (c == 39) {
      style.fg = null;
    } else if (c >= 90 && c <= 97) {
      style.fg = c - 90 + 8;
    } else if (c == 38 || c == 48) {
      final mode = i + 1 < p.length ? p[i + 1] : null;
      if (mode == 5) {
        if (c == 38 && i + 2 < p.length) {
          style.fg = _color256(p[i + 2]) ?? style.fg;
        }
        i += 2;
      } else if (mode == 2) {
        if (c == 38) {
          style.fg = _rgb(
            i + 2 < p.length ? p[i + 2] : 0,
            i + 3 < p.length ? p[i + 3] : 0,
            i + 4 < p.length ? p[i + 4] : 0,
          );
        }
        i += 4;
      }
    }
  }
}

/// The 16-color palette derived from [t]: status hues from the tokens, grays
/// from the ink ramp, brights mixed toward ink. The web themes carry 15
/// `--ansi-N` variables per theme; the Flutter tokens fold that palette into
/// ok/warn/err/accent plus the ink ramp, so the mapping is derived here.
List<Color> ansiPalette(OmpTokens t) {
  Color bright(Color c) => Color.lerp(c, t.ink, 0.4)!;
  return [
    t.ink3, // 0 black
    t.err, // 1 red
    t.ok, // 2 green
    t.warn, // 3 yellow
    t.accent, // 4 blue
    t.ink2, // 5 magenta
    t.ink2, // 6 cyan
    t.ink, // 7 white
    bright(t.ink3), // 8 bright black
    bright(t.err), // 9
    bright(t.ok), // 10
    bright(t.warn), // 11
    bright(t.accent), // 12
    bright(t.ink2), // 13
    bright(t.ink2), // 14
    bright(t.ink), // 15
  ];
}

/// Parse [input] into styled [TextSpan]s. Text style attributes come straight
/// from the SGR stream; palette indexes resolve through [palette] (see
/// [ansiPalette]) and 256/truecolor sequences carry their own color. [base]
/// supplies the default color (used plain, and dimmed at 60% alpha for SGR 2,
/// matching the web's `--ansi-d` opacity) and font.
List<TextSpan> ansiToSpans(String input, {List<Color>? palette, TextStyle? base}) {
  final style = _Style();
  final out = <TextSpan>[];
  var last = 0;

  String plain(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll(_control, '');

  void emit(String text) {
    final t = plain(text);
    if (t.isEmpty) return;
    var ts = base ?? const TextStyle();
    final defaultColor = base?.color;
    if (style.bold) ts = ts.copyWith(fontWeight: FontWeight.w700);
    if (style.dim) {
      final c = style.fg == null ? defaultColor : null;
      if (c != null) ts = ts.copyWith(color: c.withValues(alpha: 0.6));
    }
    if (style.italic) ts = ts.copyWith(fontStyle: FontStyle.italic);
    if (style.underline) {
      ts = ts.copyWith(decoration: TextDecoration.underline);
    }
    final fg = style.fg;
    if (fg is int) {
      final color = palette != null && fg < palette.length ? palette[fg] : null;
      if (color != null) {
        ts = ts.copyWith(
            color: style.dim ? color.withValues(alpha: 0.6) : color);
      }
    } else if (fg is Color) {
      ts = ts.copyWith(
          color: style.dim ? fg.withValues(alpha: 0.6) : fg);
    }
    out.add(TextSpan(text: t, style: ts));
  }

  for (final m in _escapes.allMatches(input)) {
    emit(input.substring(last, m.start));
    last = m.end;
    if (m.group(2) == 'm') _applySgr(style, m.group(1) ?? '');
  }
  emit(input.substring(last));
  return out;
}

/// [input] with every escape sequence and control character removed.
String stripAnsi(String input) =>
    input.replaceAll(_escapes, '').replaceAll('\r\n', '\n').replaceAll(_control, '');
