// Port of the SearchView behaviour suite (pure parts): lenient hit parsing,
// grouping order, snippet segmentation at the edges, label fallbacks and
// timestamp handling. No Flutter imports.

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/api/models.dart';
import 'package:omai/features/search/search_hits.dart';

SearchHit hit(Map<String, Object?> json) => SearchHit.fromJson(json);

void main() {
  group('SearchHit parsing', () {
    test('full shape', () {
      final h = hit({
        'path': '/a/s.jsonl',
        'line': 12,
        'role': 'user',
        'ts': '2026-10-12T15:30:00Z',
        'snippet': 'fix ${openSentinel}the sink$closeSentinel now',
        'sessionId': 's1',
        'cwd': '/home/user/proj',
        'title': 'fix the sink',
        'archived': true,
        'gwId': 'g1',
      });
      expect(h.path, '/a/s.jsonl');
      expect(h.line, 12);
      expect(h.role, 'user');
      expect(h.snippet, contains('the sink'));
      expect(h.archived, isTrue);
      expect(h.gwId, 'g1');
    });

    test('missing fields do not throw', () {
      final h = hit({});
      expect(h.path, '');
      expect(h.line, isNull);
      expect(h.role, isNull);
      expect(h.ts, '');
      expect(h.snippet, '');
      expect(h.sessionId, isNull);
      expect(h.cwd, isNull);
      expect(h.title, isNull);
      expect(h.archived, isFalse);
      expect(h.gwId, isNull);
    });

    test('bad types fall back instead of throwing', () {
      final h = hit({
        'path': 42,
        'line': 'nope',
        'archived': 'yes',
        'snippet': null,
        'ts': 7,
      });
      expect(h.path, '');
      expect(h.line, isNull);
      expect(h.archived, isFalse);
      expect(h.snippet, '');
      expect(h.ts, '');
    });

    test('gwId present only when live', () {
      expect(hit({'path': 'p'}).gwId, isNull);
      expect(hit({'path': 'p', 'gwId': ''}).gwId, '');
    });

    test('response parse tolerates a missing body and bad rows', () {
      expect(SearchResponse.fromJson(null).total, 0);
      expect(SearchResponse.fromJson(null).results, isEmpty);
      final r = SearchResponse.fromJson({
        'total': 5,
        'results': [
          {'path': 'a'},
          'junk',
          null,
        ],
        'indexed': {'files': 3, 'messages': 99},
      });
      expect(r.total, 5);
      expect(r.results.length, 1);
      expect(r.results.first.path, 'a');
      expect(r.indexed?.files, 3);
      expect(r.indexed?.messages, 99);
      expect(SearchResponse.fromJson({'total': 'x'}).indexed, isNull);
    });
  });

  group('grouping', () {
    test('groups by path, preserving first-seen order', () {
      final groups = groupSearchHits([
        hit({'path': 'b'}),
        hit({'path': 'a'}),
        hit({'path': 'b'}),
        hit({'path': 'c'}),
      ]);
      expect(groups.map((g) => g.path), ['b', 'a', 'c']);
      expect(groups[0].hits.length, 2);
      expect(groups[1].hits, hasLength(1));
    });

    test('empty input', () {
      expect(groupSearchHits(const []), isEmpty);
    });
  });

  group('label fallbacks', () {
    test('title wins, then cwd basename, then sessionId, then path', () {
      expect(searchHitLabel(hit({'path': 'p', 'title': 'T'})), 'T');
      expect(
        searchHitLabel(hit({'path': 'p', 'cwd': '/home/user/proj'})),
        'proj',
      );
      expect(searchHitLabel(hit({'path': 'p', 'sessionId': 's'})), 's');
      expect(searchHitLabel(hit({'path': 'p'})), 'p');
    });

    test('whitespace and empty strings fall through', () {
      expect(
        searchHitLabel(hit({'path': 'p', 'title': '  ', 'cwd': '/x/'})),
        'x',
      );
      expect(searchHitLabel(hit({'path': 'p', 'cwd': ''})), 'p');
      expect(
        searchHitLabel(hit({'path': 'p', 'title': null, 'cwd': null})),
        'p',
      );
    });
  });

  group('live detection', () {
    SessionInfo session(String gwId, String file, bool exited) => SessionInfo(
      gwId: gwId,
      cwd: '/x',
      approvalMode: 'yolo',
      resumedFrom: null,
      ompSessionId: null,
      ompSessionFile: file,
      ompSessionName: null,
      model: null,
      thinkingLevel: null,
      isStreaming: false,
      idleSec: 0,
      exited: exited,
      exitCode: null,
      protocolVersion: null,
      uptimeSec: 0,
      subscribers: 0,
      messageCount: 0,
      contextUsage: null,
      lastEventSeq: 0,
      pendingUi: const [],
    );

    test('hit gwId wins', () {
      final h = hit({'path': 'p', 'gwId': 'g1'});
      expect(searchHitIsLive(h, const []), isTrue);
      expect(liveGwIdFor(h, const []), 'g1');
    });

    test('matching live session supplies gwId; exited does not', () {
      final h = hit({'path': 'p'});
      final live = [session('g2', 'p', false), session('g3', 'q', false)];
      expect(liveGwIdFor(h, live), 'g2');
      expect(liveGwIdFor(h, [session('g4', 'p', true)]), isNull);
      expect(searchHitIsLive(h, const []), isFalse);
    });

    test('empty gwId on the hit falls through to the store', () {
      final h = hit({'path': 'p', 'gwId': ''});
      expect(liveGwIdFor(h, [session('g5', 'p', false)]), 'g5');
    });
  });

  group('snippet segmentation', () {
    test('no sentinels', () {
      expect(snippetParts('plain text'), [
        const SnippetPart('plain text', marked: false),
      ]);
    });

    test('empty snippet', () {
      expect(snippetParts(''), isEmpty);
    });

    test('mark at start and end', () {
      expect(snippetParts('$openSentinel hey$closeSentinel'), [
        const SnippetPart(' hey', marked: true),
      ]);
      expect(snippetParts('hey $openSentinel$closeSentinel'), [
        const SnippetPart('hey ', marked: false),
      ]);
    });

    test('adjacent marks stay separate runs', () {
      expect(
        snippetParts(
          'a$openSentinel b$closeSentinel$openSentinel c$closeSentinel',
        ),
        [
          const SnippetPart('a', marked: false),
          const SnippetPart(' b', marked: true),
          const SnippetPart(' c', marked: true),
        ],
      );
    });

    test('unmatched open sentinel marks the rest', () {
      expect(snippetParts('a ${openSentinel}b'), [
        const SnippetPart('a ', marked: false),
        const SnippetPart('b', marked: true),
      ]);
    });

    test('unmatched close sentinel is dropped', () {
      expect(snippetParts('a ${closeSentinel}b'), isNotEmpty);
      expect(
        snippetParts('a ${closeSentinel}b').map((p) => p.text).join(),
        'a b',
      );
    });

    test('literal <mark> stays text', () {
      final parts = snippetParts('use <mark> here');
      expect(parts.single.text, 'use <mark> here');
      expect(parts.single.marked, isFalse);
    });

    test('snippet text is never reinterpreted as markup', () {
      final parts = snippetParts('<script>x</script>');
      expect(parts.single.text, '<script>x</script>');
    });
  });

  group('hitWhen', () {
    test('formats a parseable ts in local time', () {
      final t = DateTime.parse('2026-10-12T12:00:00Z').toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      expect(
        hitWhen('2026-10-12T12:00:00Z'),
        'Oct ${t.day}, ${two(t.hour)}:${two(t.minute)}',
      );
    });

    test('empty or unparsable ts renders nothing', () {
      expect(hitWhen(''), '');
      expect(hitWhen('not a date'), '');
    });
  });
}
