// Ported from web/src/lib/render/__tests__/diff2.test.ts. Every case kept.
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/transcript/diff.dart';

void main() {
  group('parseOmpDiff', () {
    test('parses the verified probe diff into one hunk with typed rows', () {
      final p = parseOmpDiff(' 1|alpha\n-2|beta\n+2|delta\n 3|gamma');
      expect(p.adds, 1);
      expect(p.dels, 1);
      expect(p.hunks, hasLength(1));
      expect(p.hunks[0].lines, [
        const DiffRow(t: 'ctx', o: 1, n: 1, text: 'alpha'),
        const DiffRow(t: 'del', o: 2, text: 'beta'),
        const DiffRow(t: 'add', n: 2, text: 'delta'),
        const DiffRow(t: 'ctx', o: 3, n: 3, text: 'gamma'),
      ]);
    });

    test('keeps pipes in the text', () {
      final p = parseOmpDiff(' 1|a|b|c');
      expect(p.hunks[0].lines[0], const DiffRow(t: 'ctx', o: 1, n: 1, text: 'a|b|c'));
    });

    test('normalizes CRLF line endings', () {
      final p = parseOmpDiff(' 1|alpha\r\n-2|beta\r\n+2|delta\r\n\r\n 3|gamma\r');
      expect(p.adds, 1);
      expect(p.dels, 1);
      expect(p.hunks, hasLength(2));
      expect(p.hunks[0].lines[0], const DiffRow(t: 'ctx', o: 1, n: 1, text: 'alpha'));
      expect(p.hunks[1].lines[0].text, 'gamma');
    });

    test('tracks the new line number on context rows across inserts and deletes', () {
      final inserted = parseOmpDiff(' 1|a\n+2|ins\n 2|b');
      expect(inserted.hunks[0].lines[2], const DiffRow(t: 'ctx', o: 2, n: 3, text: 'b'));
      final deleted = parseOmpDiff('-1|x\n 2|after');
      expect(deleted.hunks[0].lines[1], const DiffRow(t: 'ctx', o: 2, n: 1, text: 'after'));
    });

    test('treats unrecognized lines as gap notes', () {
      final p = parseOmpDiff(' 1|ok\nnot a diff line\njunk2|y');
      expect(
          p.hunks[0].lines.map((l) => [l.t, l.text]).toList(),
          [
            ['ctx', 'ok'],
            ['gap', 'not a diff line'],
            ['gap', 'junk2|y'],
          ]);
      expect(p.adds, 0);
      expect(p.dels, 0);
    });

    test('parses multi-digit line numbers', () {
      final p = parseOmpDiff(' 12|x\n+345|y');
      expect(p.hunks[0].lines, [
        const DiffRow(t: 'ctx', o: 12, n: 12, text: 'x'),
        const DiffRow(t: 'add', n: 345, text: 'y'),
      ]);
    });

    test('splits hunks on blank lines', () {
      final p = parseOmpDiff(' 1|a\n-2|b\n\n 5|c\n+6|d');
      expect(p.hunks, hasLength(2));
      expect(p.hunks[0].lines.map((l) => l.t), ['ctx', 'del']);
      expect(p.hunks[1].lines.map((l) => l.t), ['ctx', 'add']);
      expect(p.adds, 1);
      expect(p.dels, 1);
    });

    test('turns ... lines into gap notes', () {
      final p = parseOmpDiff(' 1|a\n... skipped 12 unchanged lines\n 14|b');
      expect(p.hunks, hasLength(1));
      expect(p.hunks[0].lines[1], const DiffRow(t: 'gap', text: 'skipped 12 unchanged lines'));
    });

    test('survives an empty diff', () {
      expect(parseOmpDiff(''), const ParsedDiff([], 0, 0));
    });
  });

  group('extractFiles', () {
    test('reads a single-file edit result', () {
      final files = extractFiles('edit', {'path': 'a.py'}, {
        'diff': ' 1|alpha\n-2|beta\n+2|delta\n 3|gamma',
        'firstChangedLine': 2,
        'op': 'update',
        'path': 'a.py',
        'oldText': 'beta',
        'newText': 'delta',
      });
      expect(files, [
        const FileChange(
            path: 'a.py',
            op: 'update',
            diff: ' 1|alpha\n-2|beta\n+2|delta\n 3|gamma',
            adds: 1,
            dels: 1,
            created: false),
      ]);
    });

    test('reads per-file results and filters virtual URIs', () {
      final files = extractFiles('edit', null, {
        'perFileResults': [
          {'path': 'src/one.ts', 'op': 'update', 'diff': ' 1|a\n-2|b\n+2|c'},
          {'path': 'xd://memory/foo', 'op': 'update', 'diff': '+1|nope'},
          {'path': 'https://example.com/x', 'op': 'create', 'diff': '+1|nope'},
          {'path': 'src/two.ts', 'op': 'create', 'diff': '+1|hello\n+2|world'},
        ],
      });
      expect(files.map((f) => f.path), ['src/one.ts', 'src/two.ts']);
      expect(files[1].op, 'create');
      expect(files[1].adds, 2);
      expect(files[1].dels, 0);
      expect(files[1].created, isTrue);
      expect(files[0].op, 'update');
      expect(files[0].adds, 1);
      expect(files[0].dels, 1);
      expect(files[0].created, isFalse);
    });

    test('detects created files from all-additions starting at line 1', () {
      final files = extractFiles('edit', null, {'diff': '+1|new\n+2|file', 'op': 'update', 'path': 'n.md'});
      expect(files[0].created, isTrue);
      final edited = extractFiles('edit', null, {'diff': ' 1|old\n+2|new', 'op': 'update', 'path': 'n.md'});
      expect(edited[0].created, isFalse);
    });

    test('synthesizes an all-additions diff for a write with no result diff', () {
      final files = extractFiles('write', {'path': 'notes.md', 'content': 'hello\nworld'}, {
        'resolvedPath': '/work/notes.md',
      });
      expect(files, [
        const FileChange(
            path: '/work/notes.md',
            op: 'write',
            diff: '+1|hello\n+2|world',
            adds: 2,
            dels: 0,
            created: true),
      ]);
    });

    test('caps the synthesized write diff at 60 KB', () {
      final line = '${'x' * 99}\n';
      final files = extractFiles('write', {'path': 'big.txt', 'content': line * 1000}, {});
      final f = files[0];
      expect(f.diff.length, lessThanOrEqualTo(60 * 1024 + 200));
      expect(f.adds, lessThan(1000));
      expect(f.diff, contains('truncated'));
    });

    test('caps a single line longer than 60 KB to no rows plus the note', () {
      final files = extractFiles('write', {'path': 'huge.txt', 'content': 'y' * 100000}, {});
      expect(files[0].adds, 0);
      expect(RegExp(r'^\.\.\. truncated').hasMatch(files[0].diff), isTrue);
    });

    test('strips carriage returns from written content', () {
      final files = extractFiles('write', {'path': 'w.md', 'content': 'a\r\nb\r\n'}, {});
      expect(files[0].diff, '+1|a\n+2|b');
      expect(files[0].adds, 2);
    });

    test('replaces duplicate per-file paths, keeping the last diff', () {
      final files = extractFiles('edit', null, {
        'perFileResults': [
          {'path': 'a.ts', 'op': 'update', 'diff': '+1|one'},
          {'path': 'a.ts', 'op': 'update', 'diff': ' 1|ctx\n+2|two'},
          {'path': 'b.ts', 'op': 'update', 'diff': '+1|bee'},
        ],
      });
      expect(files.map((f) => f.path), ['a.ts', 'b.ts']);
      expect(files[0].diff, ' 1|ctx\n+2|two');
      expect(files[0].created, isFalse);
    });

    test('does not flag a prepended insert on an existing file as created', () {
      final files = extractFiles('edit', null, {
        'diff': ' 1|head\n+1|inserted\n 2|tail',
        'op': 'update',
        'path': 'n.md',
      });
      expect(files[0].created, isFalse);
      expect(files[0].adds, 1);
      expect(files[0].dels, 0);
    });

    test('prefers a real result diff over synthesis', () {
      final files = extractFiles('write', {'path': 'a.md', 'content': 'draft'}, {
        'resolvedPath': '/a.md',
        'diff': ' 1|old\n-2|gone\n+2|new',
        'op': 'update',
        'path': '/a.md',
      });
      expect(files, hasLength(1));
      expect(files[0].adds, 1);
      expect(files[0].dels, 1);
      expect(files[0].created, isFalse);
    });

    test('skips writes to virtual URIs and tools without diffs', () {
      expect(extractFiles('write', {'path': 'xd://scratch/x', 'content': 'hi'}, {}), isEmpty);
      expect(extractFiles('bash', {'command': 'ls'}, {'wallTimeMs': 5}), isEmpty);
      expect(extractFiles('read', {'path': 'a.md'}, {'fileSize': 3}), isEmpty);
      expect(extractFiles('write', {'path': 'a.md'}, {'resolvedPath': '/a.md'}), isEmpty);
    });
  });

  group('rowMarks', () {
    test('marks the changed word in paired del/add rows', () {
      final p = parseOmpDiff(' 1|let rate = 1;\n-2|let rate = 2;\n+2|let ratio = 2;\n 3|done');
      final lines = p.hunks[0].lines;
      final marks = rowMarks(lines);
      // rows 1 and 2 are the del/add pair; "rate" vs "ratio" changed
      expect(marks[1], const Range(4, 8));
      expect(marks[2], const Range(4, 9));
      expect(marks.containsKey(0), isFalse);
      expect(marks.containsKey(3), isFalse);
    });

    test('does not pair rows across a context line', () {
      final p = parseOmpDiff('-1|alpha one\n+1|alpha two\n 2|ctx\n-3|beta one\n+3|beta two');
      final lines = p.hunks[0].lines;
      final marks = rowMarks(lines);
      expect(marks.containsKey(0), isTrue);
      expect(marks.containsKey(3), isTrue);
    });

    test('gives no marks when a pair is fully rewritten', () {
      final marks = rowMarks(const [
        DiffRow(t: 'del', o: 1, text: 'completely different words here'),
        DiffRow(t: 'add', n: 1, text: 'totally other stuff appears'),
      ]);
      expect(marks, isEmpty);
    });
  });

  group('extLang', () {
    test('maps file extensions to registered languages', () {
      expect(extLang('src/lib/render/diff2.ts'), 'typescript');
      expect(extLang('main.py'), 'python');
      expect(extLang('/x/y/run.sh'), 'bash');
      expect(extLang('package.json'), 'json');
      expect(extLang('compose.yml'), 'yaml');
      expect(extLang('Dockerfile'), 'dockerfile');
      expect(extLang('styles.css'), 'css');
      expect(extLang('index.html'), 'xml');
      expect(extLang('notes.md'), 'markdown');
      expect(extLang('schema.sql'), 'sql');
    });

    test('returns null for unknown extensions and extensionless paths', () {
      expect(extLang('x.weird'), isNull);
      expect(extLang('Makefile'), isNull);
      expect(extLang(''), isNull);
    });
  });
}
