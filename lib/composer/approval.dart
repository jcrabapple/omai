// Answering a blocking extension dialog, and how its options are presented.
// Ported from web/src/lib/composer/approval.ts (minus the active/ui/haptics
// imports, which stay in the widget layer). Pure Dart, no Flutter imports.

import '../api/errors.dart' show GatewayError;
import '../wire/wire.dart' show UiRequest;

typedef OptionTone = String; // 'approve' | 'deny' | 'neutral'

final RegExp _approve =
    RegExp(r'^(allow|approve|accept|yes|ok|okay|run|proceed|continue|confirm|apply|trust)\b', caseSensitive: false);
final RegExp _deny =
    RegExp(r'^(deny|reject|refuse|block|decline|no|cancel|skip|abort|stop)\b', caseSensitive: false);

OptionTone optionTone(String label) {
  final s = label.trim();
  if (_approve.hasMatch(s)) return 'approve';
  if (_deny.hasMatch(s)) return 'deny';
  return 'neutral';
}

/// First line is the headline; the rest is the command or path, shown in a
/// mono block.
class SplitTitle {
  final String headline;
  final String detail;
  const SplitTitle(this.headline, this.detail);
}

SplitTitle splitTitle(String? title) {
  final lines = (title ?? '').replaceAll('\r\n', '\n').split('\n');
  final headline = (lines.isEmpty ? '' : lines.first).trim();
  final rest = lines.length > 1 ? lines.sublist(1).join('\n').trim() : '';
  return SplitTitle(headline, rest);
}

String editorStart(UiRequest req) {
  final t = req.text;
  return req.prefill ?? (t is String ? t : '');
}

/// One answer payload for [UiRequest]. Mirrors the web `UiAnswer` union:
/// `{value}` | `{confirmed}` | `{cancelled}`.
class UiAnswer {
  final Map<String, Object?> raw;
  const UiAnswer._(this.raw);

  static const UiAnswer cancelled = UiAnswer._({'cancelled': true});
  factory UiAnswer.value(String value) => UiAnswer._({'value': value});
  factory UiAnswer.confirmed(bool confirmed) =>
      UiAnswer._({'confirmed': confirmed});

  Map<String, Object?> toMap() => raw;

  @override
  bool operator ==(Object other) =>
      other is UiAnswer && other.raw.toString() == raw.toString();

  @override
  int get hashCode => raw.toString().hashCode;
}

typedef AnswerOutcome = String; // 'answered' | 'dropped' | 'failed'

/// A 409 means someone else answered first (or the request timed out), so the
/// dialog is dropped without a word. Other errors keep it on screen.
AnswerOutcome classifyAnswerError(Object? error) {
  if (error is GatewayError && error.status == 409) return 'dropped';
  return 'failed';
}
