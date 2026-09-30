// fileMention reducer coverage: history and live both produce FileMentionItem
// rows; malformed payloads parse defensively.
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/transcript/items.dart';
import 'package:omai/transcript/reducer.dart';
import 'package:omai/wire/wire.dart';

Map<String, Object?> mention({Object? files = const [], int? timestamp}) => {
  'role': 'fileMention',
  'timestamp': ?timestamp,
  'files': ?files,
};

Map<String, Object?> file({
  String path = 'main.dart',
  String? content = 'void main() {}',
  int? lineCount = 1,
  int? byteSize = 15,
  String? skippedReason,
  bool? image,
}) => {
  'path': path,
  'content': ?content,
  'lineCount': ?lineCount,
  'byteSize': ?byteSize,
  'skippedReason': ?skippedReason,
  'image': ?image,
};

void main() {
  test('history with a fileMention message yields a FileMentionItem', () {
    final s = reduce(
      emptyTranscript(),
      HistoryInput([
        {'role': 'user', 'timestamp': 1, 'content': 'look at @main.dart'},
        mention(timestamp: 2, files: [file()]),
      ]),
    );
    final kinds = s.items.map((i) => i.kind).toList();
    expect(kinds, contains('fileMention'));
    // The mention row sits after the user bubble it belongs to.
    expect(kinds.indexOf('fileMention'), greaterThan(kinds.indexOf('user')));
    final item =
        s.items.firstWhere((i) => i is FileMentionItem) as FileMentionItem;
    expect(item.files.length, 1);
    expect(item.files.first.path, 'main.dart');
    expect(item.files.first.lineCount, 1);
    expect(item.files.first.skippedReason, isNull);
    expect(item.files.first.image, isFalse);
  });

  test('skipped files carry the reason; images are flagged', () {
    final s = reduce(
      emptyTranscript(),
      HistoryInput([
        mention(
          files: [
            file(path: 'big.bin', content: null, skippedReason: 'tooLarge'),
            file(path: 'logo.png', content: null, image: true),
          ],
        ),
      ]),
    );
    final item = s.items.whereType<FileMentionItem>().single;
    expect(item.files[0].skippedReason, 'tooLarge');
    expect(item.files[0].content, isNull);
    expect(item.files[1].image, isTrue);
  });

  test('a live message_end carrying fileMention renders the row', () {
    var s = emptyTranscript();
    s = reduce(
      s,
      EventInput(
        OmpEvent({
          'type': 'message_end',
          'messageId': 'm1',
          'message': mention(timestamp: 5, files: [file()]),
        }),
      ),
    );
    expect(s.items.whereType<FileMentionItem>().length, 1);
  });

  test('message_start then message_end collapse into one item with the final files', () {
    // omp stamps fileMention messages with a timestamp and re-emits the full
    // message as it settles: the later frame (with the full file list) must
    // win over the earlier, emptier one.
    final start = EventInput(
      OmpEvent({
        'type': 'message_start',
        'messageId': 'm1',
        'message': mention(timestamp: 5, files: []),
      }),
    );
    final end = EventInput(
      OmpEvent({
        'type': 'message_end',
        'messageId': 'm1',
        'message': mention(
          timestamp: 5,
          files: [
            file(),
            file(path: 'other.dart'),
          ],
        ),
      }),
    );
    var s = reduce(emptyTranscript(), start);
    s = reduce(s, end);
    final items = s.items.whereType<FileMentionItem>().toList();
    expect(items.length, 1);
    expect(items.single.files.length, 2);
    expect(items.single.files[1].path, 'other.dart');
  });

  test('history then live replay of the same stamped message dedupes', () {
    // A stamped message loaded from history, then replayed live with an id:
    // both must resolve to the same key, or the transcript shows the row
    // twice.
    final m = mention(timestamp: 5, files: [file()]);
    var s = reduce(
      emptyTranscript(),
      HistoryInput([
        {'role': 'user', 'timestamp': 1, 'content': 'hi'},
        {...m, 'id': 'm1'},
      ]),
    );
    s = reduce(
      s,
      EventInput(
        OmpEvent({
          'type': 'message_end',
          'messageId': 'm1',
          'message': {...m, 'id': 'm1'},
        }),
      ),
    );
    expect(s.items.whereType<FileMentionItem>().length, 1);
  });

  test('an untimed, id-stamped message dedupes across history and live', () {
    // No timestamp: the key must fall back to the message id on both paths.
    Map<String, Object?> m() => {
      ...mention(files: [file()]),
      'id': 'm1',
    };
    var s = reduce(
      emptyTranscript(),
      HistoryInput([
        {'role': 'user', 'timestamp': 1, 'content': 'hi'},
        m(),
      ]),
    );
    s = reduce(
      s,
      EventInput(
        OmpEvent({'type': 'message_end', 'messageId': 'm1', 'message': m()}),
      ),
    );
    expect(s.items.whereType<FileMentionItem>().length, 1);
  });

  test('a live fileMention lands before trailing local user items', () {
    // omp appends the mention right after the user message it belongs to;
    // prompts the user queued locally in the meantime sit at the end and must
    // not swallow the row.
    var s = reduce(
      emptyTranscript(),
      HistoryInput([
        {'role': 'user', 'timestamp': 1, 'content': 'first'},
      ]),
    );
    s = reduce(
      s,
      LocalSendInput(localId: 'q1', text: 'queued prompt', mode: 'follow_up'),
    );
    s = reduce(
      s,
      EventInput(
        OmpEvent({
          'type': 'message_end',
          'messageId': 'm1',
          'message': mention(timestamp: 2, files: [file()]),
        }),
      ),
    );
    final kinds = s.items.map((i) => i.kind).toList();
    expect(kinds, ['user', 'fileMention', 'user']);
  });

  test('malformed payloads do not crash', () {
    final s = reduce(
      emptyTranscript(),
      HistoryInput([
        mention(
          files: [
            <String, Object?>{},
            {'path': 42, 'lineCount': 'x'},
            null,
          ],
        ),
        mention(files: 'not-a-list'),
        {'role': 'fileMention'},
      ]),
    );
    // Every message yields exactly one item: the count guard keeps this from
    // passing vacuously if reduce ever silently drops malformed messages.
    expect(s.items.whereType<FileMentionItem>().length, 3);
    for (final item in s.items.whereType<FileMentionItem>()) {
      expect(item.files.length, lessThanOrEqualTo(3));
      for (final f in item.files) {
        expect(f.path, isA<String>());
      }
    }
  });
}
