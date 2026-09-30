import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/api/models.dart';

void main() {
  group('SessionInfo', () {
    late Map<String, dynamic> fixture;

    setUp(() {
      fixture = jsonDecode(
        File('test/fixtures/api/session-info.json').readAsStringSync(),
      ) as Map<String, dynamic>;
    });

    test('advisor parses, and a gateway without the field means off', () {
      expect(
        SessionInfo.fromJson({'gwId': 'a', 'advisor': true}).advisor,
        isTrue,
      );
      expect(
        SessionInfo.fromJson({'gwId': 'a', 'advisor': false}).advisor,
        isFalse,
      );
      expect(SessionInfo.fromJson({'gwId': 'a'}).advisor, isFalse);
    });

    test('parses the captured fixture', () {
      final s = SessionInfo.fromJson(fixture);
      expect(s.gwId, 'c29060e01bc4');
      expect(s.cwd, '/home/user/projects/ohmypi-gateway');
      expect(s.approvalMode, 'yolo');
      expect(s.resumedFrom, isNull);
      expect(s.ompSessionId, '01a0ed97-3b9b-7767-bd0c-c95534b683be');
      expect(s.model, isNotNull);
      expect(s.model!.id, 'z-ai/glm-5.3-flashx');
      expect(s.model!.displayName, 'GLM 5.3 FlashX');
      expect(s.model!.contextWindow, 1048576);
      expect(s.thinkingLevel, 'low');
      expect(s.isStreaming, isFalse);
      expect(s.exited, isFalse);
      expect(s.exitCode, isNull);
      expect(s.protocolVersion, 2);
      expect(s.contextUsage, isNotNull);
      expect(s.contextUsage!.percent, closeTo(1.416, 0.001));
      expect(s.lastEventSeq, 196);
      expect(s.pendingUi, hasLength(1));
      expect(s.pendingUi.first['method'], 'select');
    });

    test('unknown fields are ignored', () {
      final s = SessionInfo.fromJson({
        ...fixture,
        'someFutureField': {'nested': true},
      });
      expect(s.gwId, 'c29060e01bc4');
    });

    test('missing optional fields are null, missing scalars default', () {
      final s = SessionInfo.fromJson({'gwId': 'x'});
      expect(s.cwd, '');
      expect(s.model, isNull);
      expect(s.contextUsage, isNull);
      expect(s.resumedFrom, isNull);
      expect(s.pendingUi, isEmpty);
      expect(s.isStreaming, isFalse);
      expect(s.exited, isFalse);
      expect(s.lastEventSeq, 0);
    });

    test('title falls back to cwd basename, prefers the session name', () {
      expect(SessionInfo.fromJson(fixture).title, 'ohmypi-gateway');
      final named = SessionInfo.fromJson({
        ...fixture,
        'ompSessionName': 'fix bug',
      });
      expect(named.title, 'fix bug');
    });

    test('empty ompSessionName falls back to the cwd basename too', () {
      final empty = SessionInfo.fromJson({...fixture, 'ompSessionName': ''});
      expect(empty.title, 'ohmypi-gateway');
    });

    // Ported from web/src/lib/__tests__/format.test.ts sessionTitle
    // regression (gateway commit ecc5752): a null name falls through to the
    // folder, and a whitespace-only name is treated as unset.
    test('null or whitespace ompSessionName falls back to the folder', () {
      final blank = SessionInfo.fromJson({...fixture, 'ompSessionName': null});
      expect(blank.title, 'ohmypi-gateway');
      final ws = SessionInfo.fromJson({...fixture, 'ompSessionName': '   '});
      expect(ws.title, 'ohmypi-gateway');
      final noCwd = SessionInfo.fromJson({...fixture, 'cwd': ''});
      expect(noCwd.title, 'Session');
    });
  });

  group('SavedSession', () {
    test('parses and prefers cwd over cwdFolder for display', () {
      final s = SavedSession.fromJson(const {
        'file': '/home/user/.omp/agent/sessions/a.jsonl',
        'mtime': 1790591422.1,
        'sizeBytes': 184320,
        'cwdFolder': '-projects-demo',
        'cwd': '/home/user/projects/demo',
        'title': 'refactor the export path',
        'running': false,
      });
      expect(s.displayCwd, '/home/user/projects/demo');
      expect(s.title, 'refactor the export path');
      expect(s.running, isFalse);
    });

    test('null cwd falls back to cwdFolder', () {
      final s = SavedSession.fromJson(const {
        'file': '/home/user/.omp/agent/sessions/b.jsonl',
        'mtime': 0,
        'sizeBytes': 10,
        'cwdFolder': 'misc',
        'cwd': null,
        'title': 't',
        'running': false,
      });
      expect(s.displayCwd, 'misc');
    });

    // Ported from web/src/lib/__tests__/format.test.ts savedFolderLabel and
    // savedTitle, including the ecc5752 null-title regression: a session with
    // no prompt snippet has a blank title and must fall back to the folder,
    // never render as an empty row.
    test('savedFolderLabel and savedTitle match the web rules', () {
      SavedSession s(String title, String cwdFolder, String? cwd) =>
          SavedSession.fromJson({
            'file': '/t/a.jsonl',
            'mtime': 0.0,
            'sizeBytes': 1,
            'cwdFolder': cwdFolder,
            'cwd': ?cwd,
            'title': title,
            'running': false,
          });
      expect(
        savedFolderLabel(s('', '-work-app', null), ['/home/me/work/app']),
        'app',
      );
      expect(savedFolderLabel(s('', '-work-app', null), []), 'work-app');
      expect(
        savedFolderLabel(
          s('', '-var-home-me-work-app', '/var/home/me/work/app'),
          [],
        ),
        'app',
      );
      expect(savedTitle(s('', '-x', '/a/b'), []), 'b');
      // The gateway normalizes a missing title to '', but a null in the
      // payload must parse blank too, not crash.
      final nullTitle = SavedSession.fromJson(const {
        'file': '/t/b.jsonl',
        'mtime': 0.0,
        'sizeBytes': 1,
        'cwdFolder': '-x',
        'cwd': '/a/b',
        'title': null,
        'running': false,
      });
      expect(nullTitle.title, '');
      expect(savedTitle(nullTitle, []), 'b');
      expect(
        savedFolderLabel(
          s('   ', '-var-home-me-work-app', '/var/home/me/work/app'),
          [],
        ),
        'app',
      );
    });
  });

  group('SessionsList', () {
    test('parses the trimmed fixture', () {
      final list = SessionsList.fromJson(
        jsonDecode(
          File('test/fixtures/api/sessions-list.json').readAsStringSync(),
        ),
      );
      expect(list.live, hasLength(1));
      expect(list.saved, hasLength(2));
      expect(list.live.first.isStreaming, isTrue);
      expect(list.live.first.title, 'fix the login bug');
      expect(list.saved[1].cwd, isNull);
      expect(list.saved[1].displayCwd, 'misc');
      expect(list.saved.every((s) => s.file.startsWith('/home/user/')), isTrue);
    });

    test('empty object yields empty lists', () {
      final list = SessionsList.fromJson(const {});
      expect(list.live, isEmpty);
      expect(list.saved, isEmpty);
    });
  });

  group('CatalogModel', () {
    test('parses an omp models --json entry, null thinking tolerated', () {
      final m = CatalogModel.fromJson(const {
        'provider': 'openrouter',
        'kind': 'openai-compat',
        'id': 'z-ai/glm-5.3-flashx',
        'selector': 'glm-5.3-flashx',
        'name': 'GLM 5.3 FlashX',
        'contextWindow': 1048576,
        'maxTokens': 131072,
        'reasoning': true,
        'thinking': null,
        'input': ['text', 'image'],
        'cost': {
          'input': 0.37,
          'output': 1.25,
          'cacheRead': 0.09,
          'cacheWrite': 0,
        },
      });
      expect(m.label, 'openrouter/z-ai/glm-5.3-flashx');
      expect(m.reasoning, isTrue);
      expect(m.thinking, isNull);
      expect(m.cost.input, 0.37);
      expect(m.contextWindow, 1048576);
    });

    test('CatalogModels skips malformed entries', () {
      final c = CatalogModels.fromJson(const {
        'models': [
          {
            'provider': 'p',
            'id': 'm',
            'selector': 'm',
            'name': 'M',
            'contextWindow': 1,
            'maxTokens': 1,
            'reasoning': false,
            'thinking': null,
            'input': [],
            'cost': {},
          },
          'garbage',
        ],
      });
      expect(c.models, hasLength(1));
    });
  });
}
