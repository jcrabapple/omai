// Ported from web/src/lib/__tests__/fork.test.ts. Every case kept.
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/transcript/fork.dart';
import 'package:omai/transcript/items.dart';

UserItem user(String text, [int? ts, bool pending = false, bool? failed]) =>
    UserItem(
      id: 'u:$text',
      text: text,
      images: 0,
      pending: pending,
      failed: failed,
      timestamp: ts,
    );

Item assistant(String text) =>
    AssistantItem(id: 'a:$text', text: text, streaming: false);

void main() {
  group('forkable', () {
    test('targets settled, echoed user messages only', () {
      expect(forkable(user('hi', 5)), isTrue);
      expect(forkable(user('hi', 5, true)), isFalse);
      expect(forkable(user('hi', 5, false, true)), isFalse);
      expect(forkable(user('   ')), isFalse);
      expect(forkable(assistant('no')), isFalse);
    });
  });

  group('userTextsBefore', () {
    final items = <Item>[
      user('first', 1),
      assistant('reply'),
      user('second', 2),
      assistant('reply2'),
      user('third', 3),
    ];

    test(
      'collects settled user texts up to but excluding the branch point',
      () {
        expect(userTextsBefore(items, items[4] as UserItem), [
          'first',
          'second',
        ]);
      },
    );

    test('is empty when forking at the first message', () {
      expect(userTextsBefore(items, items[0] as UserItem), isEmpty);
    });

    test('returns null when the branch point is not in the list', () {
      expect(userTextsBefore(items, user('ghost', 999)), isNull);
    });
  });

  group('entryForItem', () {
    final entries = const [
      SessionEntry(entryId: 'e1', role: 'user', timestamp: 1000),
      SessionEntry(entryId: 'e2', role: 'assistant', timestamp: 1500),
      SessionEntry(entryId: 'e3', role: 'user', timestamp: 2000),
    ];

    test('matches on the message timestamp', () {
      expect(entryForItem(user('x', 1000), entries)?.entryId, 'e1');
    });

    test('never matches a non-user entry', () {
      expect(entryForItem(user('x', 1500), entries), isNull);
    });

    test('misses when the live history diverged', () {
      expect(entryForItem(user('x', 9999), entries), isNull);
      expect(entryForItem(user('x'), entries), isNull);
    });
  });

  group('userTexts', () {
    test('reads string and block content, skipping empty parts', () {
      expect(
        userTexts([
          {'role': 'user', 'content': 'plain'},
          {'role': 'assistant', 'content': 'no'},
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': ' from block '},
              {'type': 'image'},
            ],
          },
          {'role': 'user', 'content': '   '},
        ]),
        ['plain', 'from block'],
      );
    });

    test('skips skill prompts, which the reducer renders as skill items', () {
      expect(
        userTexts([
          {'role': 'user', 'content': 'real question'},
          {
            'role': 'user',
            'customType': 'skill-prompt',
            'content': '[IMPORTANT: User invoked the "humanizer" skill',
          },
          {
            'role': 'custom',
            'customType': 'skill-prompt',
            'content': 'invoked the "humanizer" skill',
          },
        ]),
        ['real question'],
      );
    });

    test('joins several text blocks of one message into one entry, like the reducer', () {
      expect(
        userTexts([
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'one '},
              {'type': 'text', 'text': 'two'},
            ],
          },
        ]),
        ['one two'],
      );
    });
  });

  group('prefixMissing', () {
    test('accepts the exact prefix and anything after it', () {
      expect(prefixMissing(['a', 'b'], ['a', 'b']), isFalse);
      expect(prefixMissing(['a', 'b'], ['a', 'b', 'c']), isFalse);
    });

    test('flags truncation and divergence', () {
      expect(prefixMissing(['a', 'b'], ['a']), isTrue);
      expect(prefixMissing(['a', 'b'], ['a', 'x']), isTrue);
      expect(prefixMissing(['a'], []), isTrue);
    });
  });

  group('SessionEntry.fromJson', () {
    test('tolerates junk rows', () {
      expect(SessionEntry.fromJson('nope'), isNull);
      expect(SessionEntry.fromJson({'role': 'user'}), isNull);
      final e = SessionEntry.fromJson({
        'entryId': 'e9',
        'role': 'user',
        'timestamp': 12.0,
      });
      expect(e?.entryId, 'e9');
      expect(e?.timestamp, 12);
    });
  });
}
