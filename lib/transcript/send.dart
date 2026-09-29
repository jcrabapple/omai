// Which prompt mode a send uses, decided by whether the agent is running.
// Ported from web/src/lib/composer/send.ts (sendNote and friends).
import 'items.dart' show UserNote;

/// `prompt` | `steer` | `follow_up`.
typedef PromptMode = String;

/// Initial user-item note for a send. A steer stays "pending" until its wire echo.
UserNote? sendNote(PromptMode mode) {
  if (mode == 'steer') return 'steer-pending';
  return mode == 'follow_up' ? 'queued' : null;
}

class ModeLabel {
  final PromptMode mode;
  final String label;
  const ModeLabel(this.mode, this.label);

  @override
  bool operator ==(Object other) => other is ModeLabel && other.mode == mode && other.label == label;

  @override
  int get hashCode => Object.hash(mode, label);
}

class SendPlan {
  final ModeLabel primary;

  /// Only while streaming: queue the message for after the turn.
  final ModeLabel? secondary;
  const SendPlan(this.primary, this.secondary);
}

SendPlan sendPlan(bool streaming) => streaming
    ? const SendPlan(ModeLabel('steer', 'Steer'), ModeLabel('follow_up', 'Queue'))
    : const SendPlan(ModeLabel('prompt', 'Send'), null);

/// Enter sends the primary action; Ctrl/Cmd+Enter queues while streaming.
PromptMode modeForKey(bool streaming, bool queueModifier) {
  final plan = sendPlan(streaming);
  final secondary = plan.secondary;
  final chosen = queueModifier && secondary != null ? secondary : plan.primary;
  return chosen.mode;
}
