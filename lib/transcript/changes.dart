// Roll-up of every file a session touched: latest diff per path wins, edits
// count every file-change entry before the per-path dedupe, and the +/-
// totals come from the diffs that are shown. Ported from
// web/src/lib/transcript/changes.ts.
import 'diff.dart';
import 'items.dart';

class ChangeGroup {
  final String path;
  final FileChange file;
  const ChangeGroup(this.path, this.file);

  @override
  bool operator ==(Object other) =>
      other is ChangeGroup && other.path == path && other.file == file;

  @override
  int get hashCode => Object.hash(path, file);
}

class ChangesRollup {
  final List<ChangeGroup> groups;
  final int files;
  final int edits;
  final int adds;
  final int dels;
  const ChangesRollup(this.groups, this.files, this.edits, this.adds, this.dels);

  @override
  bool operator ==(Object other) =>
      other is ChangesRollup &&
      _groupsEq(other.groups, groups) &&
      other.files == files &&
      other.edits == edits &&
      other.adds == adds &&
      other.dels == dels;

  @override
  int get hashCode => Object.hash(groups, files, edits, adds, dels);

  @override
  String toString() =>
      'ChangesRollup($groups, files:$files, edits:$edits, +$adds -$dels)';
}

bool _groupsEq(List<ChangeGroup> a, List<ChangeGroup> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

ChangesRollup collectChanges(List<Item> items) {
  final byPath = <String, FileChange>{};
  var edits = 0;
  for (final it in items) {
    // A failed tool changed nothing on disk.
    if (it is! ToolItem || it.status == 'error' || it.files == null) continue;
    for (final f in it.files!) {
      edits += 1;
      byPath[normPath(f.path)] = f;
    }
  }
  var adds = 0;
  var dels = 0;
  final groups = <ChangeGroup>[];
  byPath.forEach((path, file) {
    groups.add(ChangeGroup(path, file));
    adds += file.adds;
    dels += file.dels;
  });
  return ChangesRollup(
      List.unmodifiable(groups), groups.length, edits, adds, dels);
}

/// Group key for a path: separators unified, trailing separators dropped.
String normPath(String path) {
  final s = path.replaceAll('\\', '/');
  return s.length > 1 ? s.replaceAll(RegExp(r'/+$'), '') : s;
}
