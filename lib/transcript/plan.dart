// Pure todo-plan helpers, ported from web/src/lib/state/plan.ts. Live
// captures show phases shaped {name, tasks: [{content, status, blocker?}]}
// where both ids may be absent and `blocked` carries a human-readable
// `blocker`.
//
// The web's known "plan list double-marking" bug (a task shown both done and
// current) is structurally impossible here: a row's look is keyed on its own
// single status, and the active task is picked with an exclusive status
// priority (in_progress, then pending, then blocked), never unioned.

/// 'pending' | 'in_progress' | 'completed' | 'blocked'
typedef TodoStatus = String;

class TodoTask {
  final String? id;
  final String content;
  final TodoStatus status;
  final String? blocker;

  const TodoTask({
    this.id,
    required this.content,
    this.status = 'pending',
    this.blocker,
  });

  @override
  bool operator ==(Object other) =>
      other is TodoTask &&
      other.id == id &&
      other.content == content &&
      other.status == status &&
      other.blocker == blocker;

  @override
  int get hashCode => Object.hash(id, content, status, blocker);
}

class TodoPhase {
  final String? id;
  final String? name;
  final List<TodoTask> tasks;

  const TodoPhase({this.id, this.name, required this.tasks});

  @override
  bool operator ==(Object other) =>
      other is TodoPhase &&
      other.id == id &&
      other.name == name &&
      _tasksEq(other.tasks, tasks);

  @override
  int get hashCode => Object.hash(id, name, tasks);

  static bool _tasksEq(List<TodoTask> a, List<TodoTask> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

const _statuses = <TodoStatus>[
  'pending',
  'in_progress',
  'completed',
  'blocked',
];

/// Optional trimmed string; ids, names and blockers are absent or empty in
/// parts of the live capture.
String? _optText(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

bool _isTodoStatus(Object? v) => _statuses.contains(v);

TodoTask? _task(Object? raw) {
  if (raw is! Map) return null;
  final content = _optText(raw['content']);
  if (content == null) return null;
  final id = _optText(raw['id']);
  final blocker = _optText(raw['blocker']);
  return TodoTask(
    id: id,
    content: content,
    status: _isTodoStatus(raw['status'])
        ? raw['status'] as TodoStatus
        : 'pending',
    blocker: blocker,
  );
}

TodoPhase? _phase(Object? raw) {
  if (raw is! Map) return null;
  final rawTasks = raw['tasks'];
  if (rawTasks is! List) return null;
  final list = <TodoTask>[];
  for (final t in rawTasks) {
    final task = _task(t);
    if (task != null) list.add(task);
  }
  if (list.isEmpty) return null;
  final id = _optText(raw['id']);
  final name = _optText(raw['name']);
  return TodoPhase(id: id, name: name, tasks: list);
}

/// Coerce omp's todoPhases into typed phases; drops junk entries and phases
/// without tasks. Non-list input (null, a string) yields [].
List<TodoPhase> normalizePhases(Object? raw) {
  if (raw is! List) return const [];
  final phases = <TodoPhase>[];
  for (final p in raw) {
    final phase = _phase(p);
    if (phase != null) phases.add(phase);
  }
  return phases;
}

/// First in_progress task, else first pending, else first blocked; null when
/// nothing is open.
TodoTask? pickActiveTask(List<TodoPhase> phases) {
  for (final want in const ['in_progress', 'pending', 'blocked']) {
    for (final p in phases) {
      for (final t in p.tasks) {
        if (t.status == want) return t;
      }
    }
  }
  return null;
}

int countDone(List<TodoPhase> phases) => phases.fold(
  0,
  (n, p) => n + p.tasks.where((t) => t.status == 'completed').length,
);

int countTotal(List<TodoPhase> phases) =>
    phases.fold(0, (n, p) => n + p.tasks.length);

/// True when some task is in_progress: the session is working even between
/// agent turns.
bool hasActiveTodo(List<TodoPhase> phases) =>
    phases.any((p) => p.tasks.any((t) => t.status == 'in_progress'));
