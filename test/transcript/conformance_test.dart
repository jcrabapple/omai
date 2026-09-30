// Conformance property: feeding a turn's /messages history and the same
// turn's live events through the reducer yields equal items, ignoring `raw`
// and timing (and the other legitimately per-source fields, as the web suite's
// normalize() does). Runs against every captured turn fixture.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/transcript/items.dart';
import 'package:omai/transcript/reducer.dart';
import 'package:omai/wire/wire.dart';

List<Map<String, Object?>> fixture(String name) =>
    (jsonDecode(File('test/fixtures/transcript/$name').readAsStringSync()) as List)
        .cast<Map<String, Object?>>();

List<Item> play(List<Map<String, Object?>> frames) {
  var s = emptyTranscript();
  for (final f in frames) {
    s = reduce(s, EventInput(OmpEvent((f['event'] as Map).cast<String, Object?>())));
  }
  return s.items;
}

void main() {
  final turnFrames = fixture('turn-tools-markdown.json');
  final messagesJson =
      jsonDecode(File('test/fixtures/transcript/messages.json').readAsStringSync())
          as Map<String, Object?>;
  final turnHistory = (messagesJson['messages'] as List).cast<Map<String, Object?>>();
  final edits = jsonDecode(File('test/fixtures/transcript/edits.json').readAsStringSync())
      as Map<String, Object?>;

  Map<String, Object?> normalized(Item it) => it.normalized();

  List<Item> fromPrefix(List<Item> items, String prefix) {
    final i = items.indexWhere((it) => it is UserItem && it.text.startsWith(prefix));
    expect(i, greaterThanOrEqualTo(0), reason: 'user prompt $prefix not found');
    return items.sublist(i);
  }

  test('skill turn: live events and history produce equal items', () {
    // The capture starts mid-turn, so both sides are compared from the user
    // prompt onward, exactly as the web suite does.
    const prefix = 'Run `ls gateway`';
    final live = fromPrefix(play(turnFrames), prefix);
    final hist =
        fromPrefix(reduce(emptyTranscript(), HistoryInput(turnHistory)).items, prefix);
    expect(live.map(normalized), hist.map(normalized));
  });

  test('edit turn: live events and history produce equal items', () {
    const prefix = 'Tighten the greeter';
    final live = fromPrefix(play((edits['events'] as List).cast<Map<String, Object?>>()), prefix);
    final hist = fromPrefix(
        reduce(emptyTranscript(), HistoryInput((edits['messages'] as List).cast<Map<String, Object?>>()))
            .items,
        prefix);
    expect(live.map(normalized), hist.map(normalized));
  });

  test('history replay of live events is idempotent', () {
    final hist = reduce(emptyTranscript(), HistoryInput(turnHistory));
    var s = hist;
    for (final f in turnFrames) {
      s = reduce(s, EventInput(OmpEvent((f['event'] as Map).cast<String, Object?>())));
    }
    expect(s.items.map((i) => i.id), hist.items.map((i) => i.id));
    expect(s.items.map(normalized), hist.items.map(normalized));
  });
}
