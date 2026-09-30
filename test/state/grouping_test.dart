// Ported from web/src/lib/state/__tests__/grouping.test.ts.
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/api/models.dart';
import 'package:omai/state/grouping.dart';

final now = DateTime(2026, 9, 29, 15, 0, 0);

double sec(DateTime d) => d.millisecondsSinceEpoch / 1000;

Map<String, Object?> _infoJson(String gwId, [Map<String, Object?>? over]) => {
      'gwId': gwId,
      'cwd': '/x',
      'approvalMode': 'yolo',
      'resumedFrom': null,
      'ompSessionId': null,
      'ompSessionFile': null,
      'ompSessionName': null,
      'model': null,
      'thinkingLevel': null,
      'isStreaming': false,
      'idleSec': 0,
      'exited': false,
      'exitCode': null,
      'protocolVersion': null,
      'uptimeSec': 0,
      'subscribers': 0,
      'messageCount': 0,
      'contextUsage': null,
      'lastEventSeq': 0,
      'pendingUi': const [],
      ...?over,
    };

SessionInfo live(String gwId, [Map<String, Object?>? over]) =>
    SessionInfo.fromJson(_infoJson(gwId, over));

SavedSession saved(String file, double mtime, [Map<String, Object?>? over]) =>
    SavedSession.fromJson({
      'file': file,
      'mtime': mtime,
      'sizeBytes': 1,
      'cwdFolder': 'f',
      'cwd': null,
      'title': file,
      'running': false,
      ...?over,
    });

void main() {
  group('groupSessions', () {
    test('splits live sessions into needs you, running and idle', () {
      final g = groupSessions([
        live('a', {'isStreaming': true}),
        live('b', {
          'pendingUi': [
            {'id': '1', 'method': 'confirm'}
          ]
        }),
        live('c'),
        live('d', {
          'isStreaming': true,
          'pendingUi': [
            {'id': '2', 'method': 'select'}
          ]
        }),
        live('gone', {'exited': true}),
      ], [], now);
      expect(g.needsYou.map((s) => s.gwId), ['b', 'd']);
      expect(g.running.map((s) => s.gwId), ['a']);
      expect(g.idle.map((s) => s.gwId), ['c']);
    });

    test('reads a session with an in_progress todo as working even when not streaming', () {
      final g = groupSessions(
          [live('plan'), live('calm')], [], now, {'plan'});
      expect(g.running.map((s) => s.gwId), ['plan']);
      expect(g.idle.map((s) => s.gwId), ['calm']);
    });

    test('pendingUi still wins over todo activity', () {
      final g = groupSessions([
        live('both', {
          'pendingUi': [
            {'id': '1', 'method': 'confirm'}
          ]
        })
      ], [], now, {'both'});
      expect(g.needsYou.map((s) => s.gwId), ['both']);
      expect(g.running, isEmpty);
    });

    test('groups pinned sessions as Ready for review between Needs you and Running', () {
      final g = groupSessions([
        live('idle1'),
        live('run1', {'isStreaming': true}),
        live('pinned1'),
        live('pinned2'),
        live('need1', {
          'pendingUi': [
            {'id': 'u', 'method': 'confirm'}
          ]
        }),
      ], [], now, {}, {'pinned1', 'pinned2'});
      expect(g.needsYou.map((s) => s.gwId), ['need1']);
      expect(g.review.map((s) => s.gwId), ['pinned1', 'pinned2']);
      expect(g.running.map((s) => s.gwId), ['run1']);
      expect(g.idle.map((s) => s.gwId), ['idle1']);
    });

    test('working outranks the pin: a flagged streaming or todo-active session stays in Running', () {
      final g = groupSessions(
          [live('both', {'isStreaming': true})], [], now, {}, {'both'});
      expect(g.running.map((s) => s.gwId), ['both']);
      expect(g.review, isEmpty);

      final todo =
          groupSessions([live('both')], [], now, {'both'}, {'both'});
      expect(todo.running.map((s) => s.gwId), ['both']);
      expect(todo.review, isEmpty);
    });

    test('pendingUi outranks the review pin', () {
      final g = groupSessions([
        live('pinned', {
          'pendingUi': [
            {'id': '1', 'method': 'select'}
          ]
        })
      ], [], now, {}, {'pinned'});
      expect(g.needsYou.map((s) => s.gwId), ['pinned']);
      expect(g.review, isEmpty);
    });

    test('buckets history by local calendar day, newest first', () {
      DateTime at(int days, [int h = 12]) => DateTime(2026, 9, 29 - days, h);
      final g = groupSessions([], [
        saved('old', sec(at(30))),
        saved('week', sec(at(5))),
        saved('yest', sec(at(1, 23))),
        saved('today-early', sec(at(0, 1))),
        saved('today-late', sec(at(0, 14))),
      ], now);
      expect(g.history.map((h) => h.key),
          [HistoryBucketKey.today, HistoryBucketKey.yesterday, HistoryBucketKey.week, HistoryBucketKey.older]);
      expect(g.history[0].items.map((s) => s.file), ['today-late', 'today-early']);
      expect(g.history[0].label, 'Today');
    });

    test('omits empty buckets', () {
      final g = groupSessions(
          [], [saved('a', sec(DateTime(2026, 9, 29, 9)))], now);
      expect(g.history.map((h) => h.key), [HistoryBucketKey.today]);
    });

    test('hides saved sessions that are live right now', () {
      final g = groupSessions([
        live('a', {'ompSessionFile': '/s/one.jsonl'})
      ], [
        saved('/s/one.jsonl', sec(DateTime(2026, 9, 29, 9))),
        saved('/s/two.jsonl', sec(DateTime(2026, 9, 29, 8))),
        saved('/s/three.jsonl', sec(DateTime(2026, 9, 29, 7)),
            {'running': true}),
      ], now);
      expect(g.history[0].items.map((s) => s.file), ['/s/two.jsonl']);
    });

    test('bucket edges', () {
      expect(historyBucket(sec(DateTime(2026, 9, 29, 0, 0, 0)), now),
          HistoryBucketKey.today);
      expect(historyBucket(sec(DateTime(2026, 9, 28, 23, 59, 59)), now),
          HistoryBucketKey.yesterday);
      expect(historyBucket(sec(DateTime(2026, 9, 22, 0, 0, 0)), now),
          HistoryBucketKey.week);
      expect(historyBucket(sec(DateTime(2026, 9, 21, 23, 59, 59)), now),
          HistoryBucketKey.older);
    });
  });
}
