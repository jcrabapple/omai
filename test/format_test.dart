// Ported from web/src/lib/__tests__/format.test.ts (the helpers that are pure
// string/number work; session-title helpers read web API types and stay web
// side). Extra coverage for the helpers the transcript uses directly.
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/format.dart';

void main() {
  group('contextLevel', () {
    test('is ok below 70, warn from 70, err from 85', () {
      expect(contextLevel(0), 'ok');
      expect(contextLevel(69.9), 'ok');
      expect(contextLevel(70), 'warn');
      expect(contextLevel(84.9), 'warn');
      expect(contextLevel(85), 'err');
      expect(contextLevel(100), 'err');
    });
    test('treats unknown as ok', () {
      expect(contextLevel(null), 'ok');
      expect(contextLevel(double.nan), 'ok');
      expect(contextLevel(double.infinity), 'ok');
    });
  });

  group('format helpers', () {
    test('basename handles trailing slashes and empties', () {
      expect(basename('/a/b/proj/'), 'proj');
      expect(basename(''), '');
      expect(basename(null), '');
    });
    test('money shows small amounts with precision', () {
      expect(money(0.0123), startsWith('\$0.01'));
      expect(money(12.5), '\$12.50');
      expect(money(0), '\$0.00');
      expect(money(0.004), '<\$0.01');
    });
    test('compactNumber rounds the way the rail shows tokens', () {
      expect(compactNumber(999), '999');
      expect(compactNumber(1200), '1.2k');
      expect(compactNumber(12000), '12k');
      expect(compactNumber(3400000), '3.4M');
      expect(compactNumber(double.nan), '');
    });
    test('priceLabel reads per-million prices or free', () {
      expect(priceLabel(0, 0), 'free');
      expect(priceLabel(null, null), 'free');
      expect(priceLabel(3, 15), '\$3 / \$15');
      expect(priceLabel(0.25, 1.25), '\$0.25 / \$1.25');
    });
  });

  group('duration', () {
    test('reads like the thinking and tool rows', () {
      expect(duration(null), '');
      expect(duration(-5), '');
      expect(duration(400), '400 ms');
      expect(duration(1200), '1.2 s');
      expect(duration(12000), '12 s');
      expect(duration(185000), '3 m 5 s');
      expect(duration(180000), '3 m');
    });
  });

  group('relativeTime', () {
    test('now, minutes, hours, days, then a short date', () {
      final now = DateTime.utc(2026, 9, 29, 12).millisecondsSinceEpoch;
      expect(relativeTime(now - 10000, now), 'now');
      expect(relativeTime(now - 5 * 60000, now), '5m');
      expect(relativeTime(now - 3 * 3600000, now), '3h');
      expect(relativeTime(now - 3 * 86400000, now), '3d');
      expect(relativeTime(now - 30 * 86400000, now), 'Aug 30');
    });
  });

  group('uptime', () {
    test('reads as the two largest units', () {
      expect(uptime(5), '5s');
      expect(uptime(12 * 60), '12m');
      expect(uptime(3 * 3600 + 5 * 60), '3h 5m');
      expect(uptime(2 * 86400 + 4 * 3600), '2d 4h');
    });
  });

  group('splitInlineCode', () {
    test('splits paired backticks into code parts', () {
      expect(splitInlineCode('Run `ls gateway` with bash'), [
        const TextPart('Run ', code: false),
        const TextPart('ls gateway', code: true),
        const TextPart(' with bash', code: false),
      ]);
    });
    test('handles several spans and edges', () {
      expect(splitInlineCode('`a` and `b`'), [
        const TextPart('a', code: true),
        const TextPart(' and ', code: false),
        const TextPart('b', code: true),
      ]);
    });
    test('leaves an unpaired or empty backtick alone', () {
      expect(splitInlineCode('cut `off here'),
          [const TextPart('cut `off here', code: false)]);
      expect(splitInlineCode('a `` b'), [const TextPart('a `` b', code: false)]);
      expect(splitInlineCode(''), isEmpty);
    });
  });

  test('firstLine', () {
    expect(firstLine('a\nb'), 'a');
    expect(firstLine(null), '');
    expect(firstLine('  x  '), 'x');
  });
}
