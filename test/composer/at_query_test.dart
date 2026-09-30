// Ported 1:1 from web/src/lib/composer/__tests__/atQuery.test.ts.
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/composer/at_query.dart';

FileIndexEntry entry(String path, [bool isDir = false]) => FileIndexEntry(
  name: path.substring(path.lastIndexOf('/') + 1),
  path: path,
  isDir: isDir,
  size: isDir ? null : 1,
);

void main() {
  group('extractAtQuery', () {
    test('triggers at line start, with an empty query', () {
      expect(
        extractAtQuery('@'),
        const AtQuery(start: 0, query: '', quoted: false),
      );
    });

    test('triggers after whitespace and captures the trailing run', () {
      expect(
        extractAtQuery('see @src/ma'),
        const AtQuery(start: 4, query: 'src/ma', quoted: false),
      );
      expect(
        extractAtQuery('see @a@b'),
        const AtQuery(start: 4, query: 'a@b', quoted: false),
      );
    });

    test('treats a line break as a trigger position', () {
      expect(
        extractAtQuery('one\ntwo\n@'),
        const AtQuery(start: 8, query: '', quoted: false),
      );
    });

    test('never fires mid-word or mid-email', () {
      expect(extractAtQuery('mail bob@example.com'), isNull);
      expect(extractAtQuery('we@are@one'), isNull);
      expect(extractAtQuery('x@"a'), isNull);
      expect(extractAtQuery('plain text'), isNull);
      expect(extractAtQuery(''), isNull);
    });

    test('ignores a trigger that already ended before the caret', () {
      expect(extractAtQuery('see @src done'), isNull);
    });

    test('opens the quoted form and allows spaces until the closing quote', () {
      expect(
        extractAtQuery('look @"my fol'),
        const AtQuery(start: 5, query: 'my fol', quoted: true),
      );
      expect(
        extractAtQuery('@"'),
        const AtQuery(start: 0, query: '', quoted: true),
      );
    });

    test('closes the quoted form at the closing quote', () {
      expect(extractAtQuery('look @"my fol"'), isNull);
      expect(
        extractAtQuery('@"old" then @ne'),
        const AtQuery(start: 12, query: 'ne', quoted: false),
      );
    });

    test('a quoted query never spans newlines (K3)', () {
      final q = extractAtQuery('@"notes\nsecond line');
      // Not a quoted query with a newline in it; whatever falls out of the
      // plain-token rule (here: null) is fine.
      expect(q?.quoted == true && q!.query.contains('\n'), isFalse);
      expect(q, isNull);
    });

    test('after a newline the plain token rule applies (K3)', () {
      expect(
        extractAtQuery('@"x\nlook @re'),
        const AtQuery(start: 9, query: 're', quoted: false),
      );
    });
  });

  group('atDirPrefix', () {
    test('splits the query into its directory part', () {
      expect(atDirPrefix('src/ma'), 'src');
      expect(atDirPrefix('a/b/c'), 'a/b');
      expect(atDirPrefix('ma'), '');
      expect(atDirPrefix(''), '');
    });
  });

  group('rankEntries', () {
    final files = [
      entry('beta'),
      entry('src', true),
      entry('readme.md'),
      entry('x-re.txt'),
      entry('alpha.txt'),
      entry('abc', true),
    ];

    test('keeps every entry with dirs first, then shorter names, on an empty query', () {
      expect(rankEntries(files, '').map((e) => e.path).toList(), [
        'abc',
        'src',
        'beta',
        'x-re.txt',
        'alpha.txt',
        'readme.md',
      ]);
    });

    test('puts exact prefixes first, then word-boundary substrings, then subsequences', () {
      expect(rankEntries(files, 're').map((e) => e.path).toList(), [
        'readme.md',
        'x-re.txt',
      ]);
      expect(
        rankEntries([
          entry('alpha.txt'),
          entry('nope.bin'),
        ], 'lt').map((e) => e.path).toList(),
        ['alpha.txt'],
      );
    });

    test('is case-insensitive', () {
      expect(rankEntries(files, 'RE').map((e) => e.path).toList(), [
        'readme.md',
        'x-re.txt',
      ]);
    });

    test('breaks tier ties dirs-first then by shorter path', () {
      expect(
        rankEntries([
          entry('ab'),
          entry('abc', true),
          entry('abcd'),
        ], 'a').map((e) => e.path).toList(),
        ['abc', 'ab', 'abcd'],
      );
    });

    test('drops non-matches', () {
      expect(rankEntries(files, 'zzz'), isEmpty);
    });
  });

  group('insertMention', () {
    test('replaces the @query token at end of text and adds no trailing space there', () {
      final res = insertMention(
        'look @s',
        const AtQuery(start: 5, query: 's', quoted: false),
        'src/main.py',
      );
      expect(res.text, 'look @src/main.py');
      expect(res.caret, 'look @src/main.py'.length);
    });

    test('replaces the whole token when the caret sits mid-word', () {
      final res = insertMention(
        '@src/main.ts',
        const AtQuery(start: 0, query: 'src/m', quoted: false),
        'src/main.py',
      );
      expect(res.text, '@src/main.py');
      expect(res.caret, '@src/main.py'.length);
    });

    test(
      'keeps an existing separator after the token instead of double-spacing',
      () {
        final res = insertMention(
          'look @s and then',
          const AtQuery(start: 5, query: 's', quoted: false),
          'src',
        );
        expect(res.text, 'look @src and then');
        expect(res.caret, 'look @src'.length);
      },
    );

    test(
      'separates the token from text that follows a closed quoted token',
      () {
        final res = insertMention(
          '@"my no"x',
          const AtQuery(start: 0, query: 'my no', quoted: true),
          'my notes',
        );
        expect(res.text, '@"my notes" x');
        expect(res.caret, '@"my notes" '.length);
      },
    );

    test('quotes paths that contain whitespace', () {
      final res = insertMention(
        'x @',
        const AtQuery(start: 2, query: '', quoted: false),
        'my notes/a b.md',
      );
      expect(res.text, 'x @"my notes/a b.md"');
      expect(res.caret, res.text.length);
    });

    test('keeps whatever preceded the trigger', () {
      final res = insertMention(
        'a b @re',
        const AtQuery(start: 4, query: 're', quoted: false),
        'readme.md',
      );
      expect(res.text.startsWith('a b @readme.md'), isTrue);
    });

    test('an unclosed quoted token keeps the tail after the caret (K1)', () {
      final res = insertMention(
        'look @"src/com and let me know',
        const AtQuery(start: 5, query: 'src/com', quoted: true),
        'src/composer',
      );
      expect(res.text, 'look @src/composer and let me know');
      expect(res.caret, 'look @src/composer'.length);
    });

    test('a closed quote on the same line still replaces through it (K1)', () {
      final res = insertMention(
        '@"src/com" done',
        const AtQuery(start: 0, query: 'src/com', quoted: true),
        'src/composer',
      );
      expect(res.text, '@src/composer done');
      expect(res.caret, '@src/composer'.length);
    });

    test('a quote on a LATER line is not used as the close (K1, K3)', () {
      final res = insertMention(
        'look @"src/com\nhe said "hi"',
        const AtQuery(start: 5, query: 'src/com', quoted: true),
        'src/composer',
      );
      expect(res.text, 'look @src/composer\nhe said "hi"');
      expect(res.caret, 'look @src/composer'.length);
    });
  });

  group('insertDrill (K2)', () {
    test('drilling without spaces stays an open plain token', () {
      final res = insertDrill(
        'see @src',
        const AtQuery(start: 4, query: 'src', quoted: false),
        'src/',
      );
      expect(res.text, 'see @src/');
      expect(res.caret, 'see @src/'.length);
      expect(
        extractAtQuery(res.text),
        const AtQuery(start: 4, query: 'src/', quoted: false),
      );
    });

    test(
      'drilling into a folder with whitespace writes an OPEN quoted token',
      () {
        final res = insertDrill(
          'see @docs',
          const AtQuery(start: 4, query: 'docs', quoted: false),
          'docs v2/',
        );
        expect(res.text, 'see @"docs v2/');
        expect(res.caret, 'see @"docs v2/'.length);
        expect(
          extractAtQuery(res.text),
          const AtQuery(start: 4, query: 'docs v2/', quoted: true),
          reason: 'the query stays open so the user can keep typing',
        );
      },
    );

    test('drilling from an already quoted token keeps it open', () {
      final res = insertDrill(
        '@"docs v2',
        const AtQuery(start: 0, query: 'docs v2', quoted: true),
        'docs v2/',
      );
      expect(res.text, '@"docs v2/');
      expect(res.caret, '@"docs v2/'.length);
      expect(
        extractAtQuery(res.text),
        const AtQuery(start: 0, query: 'docs v2/', quoted: true),
      );
    });

    test('sub-drilling a quoted token keeps one open quote', () {
      final res = insertDrill(
        '@"docs v2/',
        const AtQuery(start: 0, query: 'docs v2/', quoted: true),
        'docs v2/sub dir/',
      );
      expect(res.text, '@"docs v2/sub dir/');
      expect(res.caret, res.text.length);
    });
  });

  group('sizeLabel', () {
    test('matches the web formatting', () {
      expect(sizeLabel(entry('src', true)), 'folder');
      expect(sizeLabel(entry('a.txt')), '1 B');
      expect(
        sizeLabel(
          const FileIndexEntry(
            name: 'b',
            path: 'b',
            isDir: false,
            size: 9 * 1024,
          ),
        ),
        '9 KB',
      );
      expect(
        sizeLabel(
          const FileIndexEntry(
            name: 'c',
            path: 'c',
            isDir: false,
            size: 15 * 1024,
          ),
        ),
        '15 KB',
      );
      expect(
        sizeLabel(
          const FileIndexEntry(
            name: 'd',
            path: 'd',
            isDir: false,
            size: 3 * 1024 * 1024,
          ),
        ),
        '3 MB',
      );
    });
  });
}
