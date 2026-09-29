// Which actions the composer offers, ported from web/src/lib/composer/send.ts
// (the plan lives in ../transcript/send.dart) plus approval modes and thinking
// levels from web/src/lib/composer/modes.ts. Pure Dart, no Flutter imports.

/// `prompt` | `steer` | `follow_up`.
typedef PromptMode = String;

/// `yolo` | `write` | `always-ask`.
typedef ApprovalMode = String;

class ApprovalModeChoice {
  final ApprovalMode id;
  final String label;
  final String hint;
  const ApprovalModeChoice(this.id, this.label, this.hint);
}

const approvalModes = <ApprovalModeChoice>[
  ApprovalModeChoice('yolo', 'Yolo', 'runs tools without asking'),
  ApprovalModeChoice('write', 'Write', 'asks before edits and commands'),
  ApprovalModeChoice('always-ask', 'Always ask', 'asks before every tool'),
];

String approvalLabel(String? mode) {
  for (final m in approvalModes) {
    if (m.id == mode) return m.label;
  }
  return 'Yolo';
}

/// Levels the running model accepts: `off` plus its own efforts, in the order
/// it reports them.
List<String> thinkingChoices(List<String>? efforts) {
  if (efforts == null || efforts.isEmpty) return const [];
  return ['off', ...efforts.where((e) => e != 'off')];
}
