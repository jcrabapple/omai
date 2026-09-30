// Ported from web/src/lib/transcript/__tests__/reducer.test.ts:
// the 'last turn failure' and 'local-retry' groups.
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/transcript/items.dart';
import 'package:omai/transcript/reducer.dart';
import 'package:omai/wire/wire.dart';

UserItem okUser() =>
    const UserItem(id: 'u0', text: 'first', images: 0, pending: false);

UserItem failedUser() => const UserItem(
  id: 'u1',
  text: 'do it',
  images: 0,
  pending: false,
  failed: true,
  error: 'boom',
);

Item badAssistant() => AssistantItem(
  id: 'a1',
  text: 'partial',
  streaming: false,
  error: 'model exploded',
);

Item okAssistant() =>
    const AssistantItem(id: 'a0', text: 'done', streaming: false);

NoticeItem gaveUpNotice() => const NoticeItem(
  id: 'n1',
  level: 'error',
  text: 'Gave up retrying: rate limited',
  tag: 'retry',
);

Item erroredTool() => const ToolItem(
  id: 't1',
  toolCallId: 't1',
  toolName: 'bash',
  summary: 'ls',
  output: 'nope',
  status: 'error',
);

TranscriptState stateOf(List<Item> items) => TranscriptState(
  items: items,
  pendingUi: const [],
  running: false,
  counter: 0,
);

void main() {
  group('lastTurnFailure', () {
    test('ignores a client-side failed send: resubmission, not retry', () {
      expect(lastTurnFailure(stateOf([failedUser()])), isNull);
    });

    test('sees an assistant error in the last turn', () {
      expect(
        lastTurnFailure(stateOf([okUser(), badAssistant()])),
        'model exploded',
      );
    });

    test('sees a gave-up-retrying notice', () {
      expect(
        lastTurnFailure(stateOf([okUser(), gaveUpNotice()])),
        'Gave up retrying: rate limited',
      );
    });

    test('ignores a tool erroring mid-turn and clean turns', () {
      expect(
        lastTurnFailure(stateOf([okUser(), erroredTool(), okAssistant()])),
        isNull,
      );
      expect(lastTurnFailure(stateOf([okUser(), okAssistant()])), isNull);
    });

    test('only the last turn counts', () {
      expect(
        lastTurnFailure(stateOf([failedUser(), okUser(), okAssistant()])),
        isNull,
      );
    });

    test('a steer never becomes the turn boundary', () {
      final stale = UserItem(
        id: 'u3',
        text: 'steer',
        images: 0,
        pending: false,
        note: 'steer-pending',
        stale: true,
      );
      // A stale steer after a client-failed send is still no retry signal...
      expect(lastTurnFailure(stateOf([failedUser(), stale])), isNull);
      // ...and it must not hide a real failure that happened before it.
      expect(
        lastTurnFailure(stateOf([okUser(), badAssistant(), stale])),
        'model exploded',
      );
      final live = UserItem(
        id: 'u4',
        text: 'go on',
        images: 0,
        pending: false,
        note: 'steer',
      );
      expect(
        lastTurnFailure(stateOf([okUser(), badAssistant(), live])),
        'model exploded',
      );
    });

    test(
      'a queued follow-up does not hide the failure of the turn it waits for',
      () {
        final queued = UserItem(
          id: 'u5',
          text: 'next',
          images: 0,
          pending: true,
          note: 'queued',
        );
        expect(
          lastTurnFailure(stateOf([okUser(), badAssistant(), queued])),
          'model exploded',
        );
      },
    );

    test(
      'reads the final state: a recovery after the error is nothing to retry',
      () {
        expect(
          lastTurnFailure(stateOf([okUser(), badAssistant(), okAssistant()])),
          isNull,
        );
      },
    );

    test('reads the final state: the last failure marker wins', () {
      expect(
        lastTurnFailure(stateOf([okUser(), badAssistant(), gaveUpNotice()])),
        'Gave up retrying: rate limited',
      );
      expect(
        lastTurnFailure(stateOf([okUser(), okAssistant(), badAssistant()])),
        'model exploded',
      );
    });

    test('ignores a pending resend after a failure', () {
      final resend = UserItem(
        id: 'u2',
        text: 'again',
        images: 0,
        pending: true,
      );
      expect(lastTurnFailure(stateOf([failedUser(), resend])), isNull);
    });

    test('is null on an empty transcript', () {
      expect(lastTurnFailure(emptyTranscript()), isNull);
    });
  });

  group('local-retry', () {
    test(
      'only flags the state: history is untouched, the failure stays readable',
      () {
        final before = stateOf([
          failedUser(),
          okUser(),
          badAssistant(),
          gaveUpNotice(),
        ]);
        final s = reduce(before, const LocalRetryInput());
        expect(s.retried, isTrue);
        expect(
          s.items.map((i) => i.normalized()),
          before.items.map((i) => i.normalized()),
        );
        expect(lastTurnFailure(s), 'Gave up retrying: rate limited');
      },
    );

    test('is a no-op when a retry is already in flight', () {
      final done = reduce(
        stateOf([okUser(), badAssistant()]),
        const LocalRetryInput(),
      );
      expect(reduce(done, const LocalRetryInput()), same(done));
    });

    test('survives a history resync but ends when omp starts the new turn', () {
      final retried = reduce(
        stateOf([okUser(), badAssistant()]),
        const LocalRetryInput(),
      );
      final resynced = reduce(
        retried,
        HistoryInput([
          {'role': 'user', 'content': 'first', 'timestamp': 1},
        ]),
      );
      expect(resynced.retried, isTrue);
      final started = reduce(
        retried,
        EventInput(OmpEvent({'type': 'agent_start'})),
      );
      expect(started.retried, isFalse);
    });
  });
}
