// Small fuzzy matcher for the search palette. Ported from
// web/src/lib/palette/fuzzy.ts (pure Dart, no Flutter imports). Higher is
// better, -1 means no match. Every space-separated word of the query must
// match somewhere.

final RegExp _separator = RegExp(r'[\s\-_:/.>]');

List<int> _wordStarts(String hay) {
  final starts = <int>[];
  for (var i = 0; i < hay.length; i++) {
    if (i == 0 || _separator.hasMatch(hay[i - 1])) starts.add(i);
  }
  return starts;
}

int _subsequence(String needle, String hay) {
  var at = -1;
  var gaps = 0;
  for (var i = 0; i < needle.length; i++) {
    final ch = needle[i];
    final next = hay.indexOf(ch, at + 1);
    if (next < 0) return -1;
    if (at >= 0) gaps += next - at - 1;
    at = next;
  }
  return (100 - gaps) < 1 ? 1 : 100 - gaps;
}

int _scoreWord(String word, String hay) {
  if (hay == word) return 1000;
  if (hay.startsWith(word)) return 800 - (hay.length - word.length).clamp(0, 100);
  if (_wordStarts(hay).any((i) => hay.startsWith(word, i))) {
    return 600 - hay.indexOf(word).clamp(0, 100);
  }
  final at = hay.indexOf(word);
  if (at >= 0) return 400 - at.clamp(0, 100);
  // Fuzzy runs only for longer words; two letters matching across a title is
  // noise.
  return word.length >= 3 ? _subsequence(word, hay) : -1;
}

/// Score one string against a query.
int fuzzyScore(String query, String text) {
  final words =
      query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return 0;
  final hay = text.toLowerCase();
  var total = 0;
  for (final w in words) {
    final s = _scoreWord(w, hay);
    if (s < 0) return -1;
    total += s;
  }
  return total ~/ words.length;
}

/// Best of a primary string and weaker secondary strings (folder, keywords).
int fuzzyScoreAll(
  String query,
  String primary, [
  List<String?> secondary = const [],
]) {
  final words =
      query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return 0;
  final p = primary.toLowerCase();
  final rest = [
    for (final x in secondary)
      if (x != null) x.toLowerCase(),
  ];
  var total = 0;
  for (final w in words) {
    double best = _scoreWord(w, p).toDouble();
    for (final r in rest) {
      final s = _scoreWord(w, r);
      if (s >= 0) {
        final halved = s * 0.5;
        if (halved > best) best = halved;
      }
    }
    if (best < 0) return -1;
    total += best.toInt();
  }
  return total ~/ words.length;
}
