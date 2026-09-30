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
    // Every message still yields at most one item, with zero or more files.
    for (final item in s.items.whereType<FileMentionItem>()) {
      expect(item.files.length, lessThanOrEqualTo(3));
      for (final f in item.files) {
        expect(f.path, isA<String>());
      }
    }
  });
}
