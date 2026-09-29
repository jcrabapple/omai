// Word-level change marks for diff rows. Pure string work: given the old and
// new text of a paired -/+ row, find the shared word prefix/suffix and return
// the character range in between that actually changed. Ported from
// web/src/lib/render/wordmarks.ts (wordMarks only; markHtml is HTML rendering
// and stays web-only).

class Range {
  final int start;
  final int end;

  const Range(this.start, this.end);

  @override
  bool operator ==(Object other) => other is Range && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'Range($start, $end)';
}

class _Tok {
  final String text;
  final int start;
  final int end;
  const _Tok(this.text, this.start, this.end);
}

/// Identifier runs stay whole; whitespace runs and single punctuation chars are tokens too.
final RegExp _token = RegExp(r'[A-Za-z0-9_]+|\s+|[^\sA-Za-z0-9_]');

List<_Tok> _tokenize(String s) => _token
    .allMatches(s)
    .map((m) => _Tok(m[0]!, m.start, m.end))
    .toList(growable: false);

/// Changed share of a string; an empty string counts as fully changed.
double _changedRatio(String s, Range r) => s.isEmpty ? 1 : (r.end - r.start) / s.length;

/// Character range of the changed middle of `s`, from `from` to `to` token
/// indexes. An empty middle collapses to the insertion point.
Range _rangeOf(List<_Tok> t, int from, int to) {
  if (from < to) return Range(t[from].start, t[to - 1].end);
  final at = from < t.length ? from : t.length;
  final edge = at == 0 ? 0 : t[at - 1].end;
  return Range(edge, edge);
}

/// Word-level marks for a pair of changed lines: common token prefix and
/// suffix, whatever is in between changed. Null when nothing changed or so
/// much changed (more than ~70% of both strings) that marks would just be noise.
(Range, Range)? wordMarks(String a, String b) {
  if (a == b) return null;
  final ta = _tokenize(a);
  final tb = _tokenize(b);
  final min = ta.length < tb.length ? ta.length : tb.length;
  var pre = 0;
  while (pre < min && ta[pre].text == tb[pre].text) {
    pre++;
  }
  var suf = 0;
  final maxSuf = min - pre;
  while (suf < maxSuf && ta[ta.length - 1 - suf].text == tb[tb.length - 1 - suf].text) {
    suf++;
  }
  if (ta.length - pre - suf <= 0 && tb.length - pre - suf <= 0) return null;

  final ra = _rangeOf(ta, pre, ta.length - suf);
  final rb = _rangeOf(tb, pre, tb.length - suf);
  if (_changedRatio(a, ra) > 0.7 && _changedRatio(b, rb) > 0.7) return null;
  return (ra, rb);
}
