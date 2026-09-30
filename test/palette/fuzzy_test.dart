// Ported from web/src/lib/palette/__tests__/fuzzy.test.ts.

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/palette/fuzzy.dart';

void main() {
  group('fuzzyScore', () {
    test('ranks exact, prefix, word start, substring in that order', () {
      final exact = fuzzyScore('theme', 'theme');
      final prefix = fuzzyScore('theme', 'themes and more');
      final word = fuzzyScore('theme', 'toggle theme');
      final inner = fuzzyScore('theme', 'xthemex');
      expect(exact, greaterThan(prefix));
      expect(prefix, greaterThan(word));
      expect(word, greaterThan(inner));
      expect(inner, greaterThan(0));
    });

    test('needs every word to match', () {
      expect(fuzzyScore('new sess', 'New session'), greaterThan(0));
      expect(fuzzyScore('new zebra', 'New session'), -1);
    });

    test('is case-insensitive and treats an empty query as a match', () {
      expect(fuzzyScore('NEW', 'new session'), greaterThan(0));
      expect(fuzzyScore('  ', 'anything'), 0);
    });

    test('allows a scattered match only for longer words', () {
      expect(fuzzyScore('nsn', 'new session'), greaterThan(0));
      expect(fuzzyScore('ns', 'new session'), -1);
    });
  });

  group('fuzzyScoreAll', () {
    test('counts secondary text at half weight', () {
      final primary = fuzzyScoreAll('compact', 'Compact context', ['summarize']);
      final secondary =
          fuzzyScoreAll('summarize', 'Compact context', ['summarize']);
      expect(secondary, greaterThan(0));
      expect(primary, greaterThan(secondary));
    });

    test('lets different words match different fields', () {
      expect(
        fuzzyScoreAll('work status', 'Work', ['show status']),
        greaterThan(0),
      );
      expect(fuzzyScoreAll('work nothing', 'Work', ['show status']), -1);
    });
  });
}
