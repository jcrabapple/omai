// Pure transcript reducer. History (GET /messages) and live events go through
// the same message appliers, so the same turn yields the same items either way.
// Ported from web/src/lib/transcript/reducer.ts.
//
// omp emits whole message objects, not just deltas: every message_update carries
// the message so far in `message` (and `assistantMessageEvent.partial`). Text is
// always taken from those blocks. Deltas are never appended, which keeps
// replays, resumes and a missed frame harmless.
import 'dart:convert' show jsonEncode, JsonEncoder;

import '../wire/wire.dart';
import 'diff.dart' show extractFiles, FileChange;
import 'items.dart';
import 'send.dart';

class TranscriptState {
  final List<Item> items;
  final List<UiRequest> pendingUi;

  /// Between agent_start and agent_end.
  final bool running;

  /// Source of ids for items that have no natural key.
  final int counter;

  /// A backend retry (POST /retry) was accepted and is waiting for omp to
  /// start the turn. Hides the Retry chip in the meantime; cleared on the
  /// next agent_start, when omp's events own the transcript again.
  final bool retried;

  const TranscriptState({
    required this.items,
    required this.pendingUi,
    required this.running,
    required this.counter,
    this.retried = false,
  });
}

sealed class TranscriptInput {
  const TranscriptInput();
}

class HistoryInput extends TranscriptInput {
  final List<Map<String, Object?>> messages;
  final bool streaming;
  const HistoryInput(this.messages, {this.streaming = false});
}

class EventInput extends TranscriptInput {
  final OmpEvent event;

  /// Client clock for the event, if the caller supplied one.
  final int? at;
  const EventInput(this.event, {this.at});
}

class LocalSendInput extends TranscriptInput {
  final String localId;
  final String text;
  final PromptMode mode;
  final List<Object?>? images;
  const LocalSendInput({
    required this.localId,
    required this.text,
    required this.mode,
    this.images,
  });
}

/// A backend retry (POST /retry, omp abort_retry) was accepted. Only flags
/// the state: the failed turn stays in the transcript until omp's own events
/// replace it, so a retry that never produces new events cannot silently
/// rewrite history.
class LocalRetryInput extends TranscriptInput {
  const LocalRetryInput();
}

class LocalSendFailedInput extends TranscriptInput {
  final String localId;
  final String error;
  const LocalSendFailedInput({required this.localId, required this.error});
}

/// Retry a failed local send: the SAME bubble flips back to pending (no
/// second bubble is created).
class LocalSendRetryInput extends TranscriptInput {
  final String localId;
  const LocalSendRetryInput(this.localId);
}

class PendingUiInput extends TranscriptInput {
  final List<UiRequest> requests;
  const PendingUiInput(this.requests);
}

TranscriptState emptyTranscript() =>
    const TranscriptState(items: [], pendingUi: [], running: false, counter: 0);

class _Work {
  final List<Item> items;
  final List<UiRequest> pendingUi;
  bool running;
  int counter;
  bool retried;
  _Work(this.items, this.pendingUi, this.running, this.counter, this.retried);
}

class _Ctx {
  final bool live; // Live event (as opposed to a history load).
  final int? at; // Client clock for the event, if the caller supplied one.
  const _Ctx(this.live, this.at);
}

TranscriptState reduce(TranscriptState state, TranscriptInput input) {
  switch (input) {
    case HistoryInput():
      return fromHistory(state, input.messages, input.streaming);
    case EventInput():
      return onEvent(state, input.event, input.at);
    case LocalSendInput():
      if (state.items.any(
        (it) => it is UserItem && it.localId == input.localId,
      )) {
        return state;
      }
      final d = _open(state);
      d.items.add(
        UserItem(
          id: 'local:${input.localId}',
          localId: input.localId,
          text: input.text,
          images: input.images?.length ?? 0,
          pending: true,
          note: sendNote(input.mode),
        ),
      );
      return _close(d);
    case LocalSendFailedInput():
      final i = state.items.indexWhere(
        (it) => it is UserItem && it.localId == input.localId,
      );
      if (i < 0) return state;
      final d = _open(state);
      final prev = d.items[i] as UserItem;
      d.items[i] = prev.copyWith(
        pending: false,
        failed: true,
        error: input.error,
      );
      return _close(d);
    case LocalSendRetryInput():
      final i = state.items.indexWhere(
        (it) =>
            it is UserItem && it.localId == input.localId && it.failed == true,
      );
      if (i < 0) return state;
      final d = _open(state);
      final prev = d.items[i] as UserItem;
      d.items[i] = prev.copyWith(
        pending: true,
        failed: false,
        clearError: true,
      );
      return _close(d);
    case LocalRetryInput():
      // An accepted retry only hides the chip (web: `retried`). The failed
      // turn stays in the transcript until omp's own events replace it.
      return state.retried ? state : _copyWith(state, retried: true);
    case PendingUiInput():
      final d = _open(state);
      d.pendingUi
        ..clear()
        ..addAll(input.requests.where(isBlockingUi));
      return _close(d);
  }
}

_Work _open(TranscriptState s) => _Work(
  s.items.toList(),
  s.pendingUi.toList(),
  s.running,
  s.counter,
  s.retried,
);

TranscriptState _close(_Work d) => TranscriptState(
  items: List.unmodifiable(d.items),
  pendingUi: List.unmodifiable(d.pendingUi),
  running: d.running,
  counter: d.counter,
  retried: d.retried,
);

TranscriptState _copyWith(TranscriptState s, {bool? retried}) =>
    TranscriptState(
      items: s.items,
      pendingUi: s.pendingUi,
      running: s.running,
      counter: s.counter,
      retried: retried ?? s.retried,
    );

// ---------------------------------------------------------- failed turns

/// The last ordinary user message: a turn boundary. Steers and queued
/// follow-ups are not boundaries: searching from them as the turn start would
/// hide a real failure behind them.
int _turnStart(List<Item> items) {
  for (var i = items.length - 1; i >= 0; i--) {
    final it = items[i];
    if (it is UserItem &&
        it.note != 'steer' &&
        it.note != 'steer-pending' &&
        it.note != 'queued') {
      return i;
    }
  }
  return -1;
}

/// Error text when the last turn ended in failure, else null. Only backend
/// turn failures count: an assistant error message, or the 'gave up
/// retrying' notice. A client-side failed send never appears here: omp never
/// saw that prompt, so retrying it (abort_retry) is wrong; it is resubmission
/// territory. The FINAL state of the turn decides: the last failure marker
/// wins, and a healthy assistant message after the last marker means omp
/// recovered (its auto-retry succeeded), so there is nothing to retry. A tool
/// erroring mid-turn does not fail the turn, so tool statuses are ignored.
String? lastTurnFailure(TranscriptState s) {
  final start = _turnStart(s.items);
  if (start < 0) return null;
  var markerAt = -1;
  var healthyAt = -1;
  String? text;
  for (var i = start + 1; i < s.items.length; i++) {
    final it = s.items[i];
    if (it is AssistantItem) {
      if (it.error != null) {
        markerAt = i;
        text = it.error;
      } else {
        healthyAt = i;
      }
    } else if (it is NoticeItem && it.tag == 'retry' && it.level == 'error') {
      markerAt = i;
      text = it.text;
    }
  }
  return markerAt > healthyAt ? text : null;
}

// ------------------------------------------------------------------ helpers

Map<String, Object?>? _rec(Object? v) => v is Map<String, Object?>
    ? v
    : (v is Map && v is! List ? v.cast<String, Object?>() : null);

/// String content or content blocks -> text, thinking, image count, tool calls.
Split splitContent(Object? content) {
  if (content is String) return Split(content, '', 0, const []);
  final outText = StringBuffer();
  final outThinking = StringBuffer();
  var images = 0;
  final calls = <ToolCallBlock>[];
  final list = listOf(content);
  if (list == null) return Split('', '', 0, const []);
  for (final b in list) {
    final m = _rec(b);
    switch (m?['type']) {
      case 'text':
        outText.write(m?['text'] ?? '');
      case 'thinking':
        outThinking.write(m?['thinking'] ?? '');
      case 'image':
        images += 1;
      case 'toolCall':
        final call = ToolCallBlock.from(b);
        if (call != null) calls.add(call);
    }
  }
  return Split(
    outText.toString(),
    outThinking.toString(),
    images,
    List.unmodifiable(calls),
  );
}

class Split {
  final String text;
  final String thinking;
  final int images;
  final List<ToolCallBlock> calls;
  const Split(this.text, this.thinking, this.images, this.calls);
}

final JsonEncoder _pretty = const JsonEncoder.withIndent('  ');

/// Text of a tool result: a toolResult message, a `{content, details}` result,
/// or a plain string.
String resultText(Object? r) {
  if (r == null) return '';
  if (r is String) return r;
  final o = _rec(r);
  final c = (o != null && o.containsKey('content')) ? o['content'] : r;
  if (c is String) return c;
  final list = listOf(c);
  if (list != null) {
    return list
        .map(_rec)
        .where((x) => x?['type'] == 'text')
        .map((x) => '${x?['text'] ?? ''}')
        .join('\n');
  }
  return _pretty.convert(r);
}

String _keyOf(Map<String, Object?> m, String? messageId, String fallback) {
  final ts = m['timestamp'];
  if (ts is num) return '${m['role']}:${ts.toInt()}';
  return '${m['role']}:${messageId != null && messageId.isNotEmpty ? 'id:$messageId' : fallback}';
}

const List<String> _summaryKeys = [
  'command',
  'path',
  'file_path',
  'pattern',
  'query',
  'url',
];

String summarize(Map<String, Object?>? args, String? intent) {
  if (intent != null && intent.isNotEmpty) return intent;
  if (args == null) return '';
  for (final k in _summaryKeys) {
    final v = args[k];
    if (v is String && v.isNotEmpty) return v;
  }
  if (args.isEmpty) return '';
  final j = jsonEncode(args);
  return j.length > 300 ? '${j.substring(0, 300)}…' : j;
}

({Map<String, Object?>? args, String? intent}) _normArgs(Object? args) {
  final o = _rec(args);
  if (o == null) return (args: null, intent: null);
  final rest = <String, Object?>{
    for (final e in o.entries)
      if (e.key != 'i') e.key: e.value,
  };
  final i = o['i'];
  return (args: rest, intent: i is String && i.isNotEmpty ? i : null);
}

const Map<String, int> _rank = {'thinking': 0, 'assistant': 1, 'tool': 2};

/// Add an item. Items of one message stay together in thinking, text, tools order.
void _place(_Work d, Item item) {
  final key = item.messageKey;
  final rank = _rank[item.kind];
  if (key == null || rank == null) {
    d.items.add(item);
    return;
  }
  var after = -1;
  var before = -1;
  for (var i = 0; i < d.items.length; i++) {
    final it = d.items[i];
    if (it.messageKey != key) continue;
    final r = _rank[it.kind];
    if (r == null) continue;
    if (r <= rank) {
      after = i;
    } else if (before < 0) {
      before = i;
    }
  }
  final at = after >= 0 ? after + 1 : (before >= 0 ? before : d.items.length);
  d.items.insert(at, item);
}

int _findKeyed(_Work d, String kind, String key) =>
    d.items.indexWhere((it) => it.kind == kind && it.messageKey == key);

void _put(_Work d, int i, Item item) {
  if (i >= 0) {
    d.items[i] = item;
  } else {
    _place(d, item);
  }
}

String _nextId(_Work d, String prefix) {
  d.counter += 1;
  return '$prefix:${d.counter}';
}

// ----------------------------------------------------------------- messages

void _applyMessage(
  _Work d,
  Map<String, Object?> m,
  _Ctx ctx, {
  String? messageId,
  required bool ending,
  bool? thinkingStreaming,
  required String fallback,
}) {
  switch (m['role']) {
    case 'user':
      _applyUser(d, m, ctx, messageId: messageId, fallback: fallback);
    case 'assistant':
      _applyAssistant(
        d,
        m,
        ctx,
        messageId: messageId,
        ending: ending,
        thinkingStreaming: thinkingStreaming,
        fallback: fallback,
      );
    case 'toolResult':
      _applyToolResult(d, m, ctx);
    case 'custom':
      _applyCustom(d, m, ctx, messageId: messageId, fallback: fallback);
    case 'fileMention':
      _applyFileMention(d, m, messageId: messageId, fallback: fallback);
  }
}

/// The fileMention message right after a user prompt: a compact row per
/// attached file. Defensively parsed: a malformed payload yields an item with
/// whatever files could be read, never a crash.
void _applyFileMention(
  _Work d,
  Map<String, Object?> m, {
  String? messageId,
  required String fallback,
}) {
  final key = _keyOf(m, messageId, fallback);
  if (_findKeyed(d, 'fileMention', key) >= 0) return;
  final files = FileMentionFile.listFrom(m['files']);
  d.items.add(
    FileMentionItem(id: 'fm:$key', files: files, messageKey: key, raw: m),
  );
}

void _applyUser(
  _Work d,
  Map<String, Object?> m,
  _Ctx ctx, {
  String? messageId,
  required String fallback,
}) {
  final b = splitContent(messageContent(m));
  if (b.text.isEmpty && b.images == 0) return;
  final key = _keyOf(m, messageId, fallback);
  if (_findKeyed(d, 'user', key) >= 0) return;
  final steering = messageSteering(m);

  if (ctx.live) {
    final text = b.text.trim();
    // Steer echoes only confirm steers; plain echoes never swallow one. Without
    // this split, a normal prompt matching a pending steer would merge into it,
    // and a steering echo would upgrade an unrelated queued follow-up.
    bool matches(Item it) =>
        it is UserItem &&
        it.pending &&
        it.text.trim() == text &&
        (steering ? it.note == 'steer-pending' : it.note != 'steer-pending');
    final i = d.items.indexWhere(matches);
    if (i >= 0) {
      final prev = d.items[i] as UserItem;
      // A steering echo confirms a steer; a plain echo of a queued follow-up is
      // the next turn picking it up, so it reads as an ordinary message from
      // here on.
      final note = steering
          ? 'steer'
          : prev.note == 'queued'
          ? null
          : prev.note;
      d.items[i] = prev.copyWith(
        pending: false,
        note: note,
        clearNote: note == null,
        messageKey: key,
        timestamp: messageTimestamp(m),
        raw: m,
      );
      return;
    }
    if (steering) {
      // The turn ended before this steer's echo: the stale item is still the
      // same message, so confirm it in place instead of adding a second bubble.
      final j = d.items.indexWhere(
        (it) =>
            it is UserItem &&
            it.note == 'steer-pending' &&
            it.stale == true &&
            it.text.trim() == text,
      );
      if (j >= 0) {
        d.items[j] = (d.items[j] as UserItem).copyWith(
          pending: false,
          stale: false,
          note: 'steer',
          messageKey: key,
          timestamp: messageTimestamp(m),
          raw: m,
        );
        return;
      }
    }
  }
  d.items.add(
    UserItem(
      id: 'u:$key',
      messageKey: key,
      text: b.text,
      images: b.images,
      pending: false,
      note: steering ? 'steer' : (ctx.live ? 'other-client' : null),
      timestamp: messageTimestamp(m),
      raw: m,
    ),
  );
}

void _applyAssistant(
  _Work d,
  Map<String, Object?> m,
  _Ctx ctx, {
  String? messageId,
  required bool ending,
  bool? thinkingStreaming,
  required String fallback,
}) {
  final key = _keyOf(m, messageId, fallback);
  final b = splitContent(messageContent(m));

  if (b.thinking.isNotEmpty) {
    final i = _findKeyed(d, 'thinking', key);
    final prev = i >= 0 ? d.items[i] as ThinkingItem : null;
    final streaming = !ending && thinkingStreaming == true;
    final endedAt = !streaming && (prev?.streaming ?? false)
        ? (ctx.at ?? prev?.endedAt)
        : prev?.endedAt;
    _put(
      d,
      i,
      ThinkingItem(
        id: 'th:$key',
        messageKey: key,
        text: b.thinking,
        streaming: streaming,
        startedAt: prev?.startedAt ?? ctx.at ?? messageTimestamp(m),
        endedAt: endedAt,
        raw: m,
      ),
    );
  }

  final errorMessage = strOf(m, 'errorMessage');
  final error = (errorMessage != null && errorMessage.isNotEmpty)
      ? errorMessage
      : (m['stopReason'] == 'error' ? 'The model returned an error' : null);
  if (b.text.isNotEmpty || error != null) {
    final i = _findKeyed(d, 'assistant', key);
    _put(
      d,
      i,
      AssistantItem(
        id: 'a:$key',
        messageKey: key,
        text: b.text,
        streaming: !ending,
        model: strOf(m, 'model'),
        provider: strOf(m, 'provider'),
        usage: mapField(m, 'usage'),
        stopReason: strOf(m, 'stopReason'),
        error: error,
        timestamp: messageTimestamp(m),
        duration: intOf(m, 'duration'),
        ttft: intOf(m, 'ttft'),
        raw: m,
      ),
    );
  }

  for (final call in b.calls) {
    _upsertTool(d, (
      id: call.id,
      name: call.name,
      args: call.arguments,
      intent: call.intent,
      messageKey: key,
      output: null,
      status: null,
      details: null,
      startedAt: null,
      endedAt: null,
      call: call,
      result: null,
    ));
  }
}

void _applyToolResult(_Work d, Map<String, Object?> m, _Ctx ctx) {
  final toolCallId = messageToolCallId(m);
  if (toolCallId == null) return;
  ToolItem? prev;
  for (final it in d.items) {
    if (it is ToolItem && it.toolCallId == toolCallId) {
      prev = it;
      break;
    }
  }
  _upsertTool(d, (
    id: toolCallId,
    name: messageToolName(m),
    args: null,
    intent: null,
    messageKey: null,
    output: resultText(m),
    status: messageIsError(m) ? 'error' : 'done',
    details: messageDetails(m),
    startedAt: null,
    endedAt: prev?.endedAt ?? ctx.at ?? messageTimestamp(m),
    call: null,
    result: m,
  ));
}

void _applyCustom(
  _Work d,
  Map<String, Object?> m,
  _Ctx ctx, {
  String? messageId,
  required String fallback,
}) {
  final key = _keyOf(m, messageId, fallback);
  final existing = d.items.indexWhere(
    (it) => it.messageKey == key && (it.kind == 'skill' || it.kind == 'notice'),
  );
  if (existing >= 0) return;
  final b = splitContent(messageContent(m));

  if (m['customType'] == 'skill-prompt') {
    final details = messageDetails(m);
    final prompt = details != null && details['prompt'] is String
        ? details['prompt'] as String
        : null;
    final detailsName = details?['name'];
    final firstLine = b.text.split('\n').first;
    final match = RegExp('invoked the "([^"]+)" skill').firstMatch(firstLine);
    final name = (detailsName is String && detailsName.isNotEmpty)
        ? detailsName
        : (match?.group(1) ?? 'skill');
    final lineCount = details?['lineCount'];
    final skill = SkillItem(
      id: 's:$key',
      messageKey: key,
      name: name,
      content: b.text,
      prompt: prompt,
      lineCount: lineCount is num ? lineCount.toInt() : null,
      timestamp: messageTimestamp(m),
      raw: m,
    );
    if (ctx.live) {
      final i = d.items.indexWhere(
        (it) =>
            it is UserItem &&
            it.pending &&
            ((prompt != null && it.text.trim() == prompt) ||
                it.text.trim().startsWith('/')),
      );
      if (i >= 0) {
        final localId = d.items[i].id;
        d.items[i] = SkillItem(
          id: localId,
          messageKey: skill.messageKey,
          name: skill.name,
          content: skill.content,
          prompt: skill.prompt,
          lineCount: skill.lineCount,
          timestamp: skill.timestamp,
          raw: skill.raw,
        );
        return;
      }
    }
    d.items.add(skill);
    return;
  }

  if (!messageDisplay(m) || b.text.isEmpty) return;
  d.items.add(
    NoticeItem(
      id: 'n:$key',
      messageKey: key,
      level: 'info',
      text: b.text,
      raw: m,
    ),
  );
}

// -------------------------------------------------------------------- tools

typedef _ToolPatch = ({
  String id,
  String? name,
  Object? args,
  String? intent,
  String? messageKey,
  String? output,
  String? status,
  Object? details,
  int? startedAt,
  int? endedAt,
  Object? call,
  Object? result,
});

void _upsertTool(_Work d, _ToolPatch p) {
  final i = d.items.indexWhere((it) => it is ToolItem && it.toolCallId == p.id);
  final prev = i >= 0 ? d.items[i] as ToolItem : null;
  final n = _normArgs(p.args);
  final newArgs = n.args;
  final args = (newArgs != null && newArgs.isNotEmpty)
      ? newArgs
      : (prev?.args ?? newArgs);
  // TS: p.intent || n.intent || prev?.intent — empty strings fall through.
  String? intentOf(String? a, String? b, String? c) =>
      a != null && a.isNotEmpty ? a : (b != null && b.isNotEmpty ? b : c);
  final intent = intentOf(p.intent, n.intent, prev?.intent);
  // A replayed start or update must not reopen a tool that already finished.
  final finished = prev != null && prev.status != 'running';
  final status = p.status ?? (finished ? prev.status : 'running');
  final raw = <String, Object?>{
    ...?_rec(prev?.raw),
    if (p.call != null) 'call': p.call,
    if (p.result != null) 'result': p.result,
  };
  final item = ToolItem(
    id: 'tool:${p.id}',
    messageKey: prev?.messageKey ?? p.messageKey,
    toolCallId: p.id,
    toolName: (p.name != null && p.name!.isNotEmpty)
        ? p.name!
        : (prev?.toolName ?? 'tool'),
    args: args,
    summary: summarize(args, intent),
    intent: intent,
    output: finished && p.status == null
        ? prev.output
        : (p.output ?? prev?.output ?? ''),
    status: status,
    details: p.details ?? prev?.details,
    startedAt: prev?.startedAt ?? p.startedAt,
    endedAt: p.endedAt ?? prev?.endedAt,
    raw: raw,
  );
  // Results carry the diff details (edit) or just enough to synthesize from the
  // call arguments (write). Computed whenever a result has been applied and the
  // inputs for this tool are present, so a late tool_execution_start still
  // yields the same files as an in-order stream. Errored results contribute
  // nothing: the change never happened.
  List<FileChange>? files;
  if (p.result != null || _rec(prev?.raw)?['result'] != null) {
    final extracted = status == 'error'
        ? const <FileChange>[]
        : extractFiles(item.toolName, item.args, item.details);
    files = extracted.isEmpty ? null : extracted;
  } else {
    files = prev?.files;
  }
  final withFiles = item.copyWith(files: files);
  if (i >= 0) {
    d.items[i] = withFiles;
  } else {
    _place(d, withFiles);
  }
}

void _interrupt(_Work d) {
  for (var i = 0; i < d.items.length; i++) {
    final it = d.items[i];
    if (it is ToolItem && it.status == 'running') {
      d.items[i] = it.copyWith(status: 'interrupted');
    } else if ((it is AssistantItem || it is ThinkingItem)) {
      if (it is AssistantItem && it.streaming) {
        d.items[i] = it.copyWith(streaming: false);
      }
      if (it is ThinkingItem && it.streaming) {
        d.items[i] = it.copyWith(streaming: false);
      }
    }
  }
}

// ------------------------------------------------------------------ history

TranscriptState fromHistory(
  TranscriptState prev,
  List<Map<String, Object?>> messages,
  bool streaming,
) {
  final d = _Work(
    [],
    prev.pendingUi.toList(),
    streaming,
    prev.counter,
    prev.retried,
  );
  for (var i = 0; i < messages.length; i++) {
    _applyMessage(
      d,
      messages[i],
      const _Ctx(false, null),
      ending: true,
      fallback: 'h$i',
    );
  }
  if (!streaming) _interrupt(d);

  // Keep local sends the server has not echoed yet. Text match against recent
  // user messages.
  final userItems = d.items.whereType<UserItem>().toList(growable: false);
  final recent = userItems.length <= 5
      ? userItems
      : userItems.sublist(userItems.length - 5);
  final used = <UserItem>{};
  for (final it in prev.items) {
    if (it is! UserItem || !it.pending) continue;
    final text = it.text.trim();
    UserItem? hit;
    for (final r in recent) {
      if (!used.contains(r) && r.text.trim() == text) {
        hit = r;
        break;
      }
    }
    if (hit != null) {
      used.add(hit);
    } else if (!streaming && it.note == 'steer-pending') {
      d.items.add(it.copyWith(pending: false, stale: true));
    } else {
      d.items.add(it);
    }
  }
  return _close(d);
}

// ------------------------------------------------------------------- events

TranscriptState onEvent(TranscriptState state, OmpEvent event, int? at) {
  final ctx = _Ctx(true, at);
  switch (event.type) {
    case 'agent_start':
      if (state.running) return state;
      final d = _open(state);
      d.running = true;
      // omp picked the retry (or any new turn) up: its events own the
      // transcript from here, so the optimistic chip hiding ends.
      d.retried = false;
      return _close(d);
    case 'agent_end':
      final d = _open(state);
      d.running = false;
      _interrupt(d);
      // Steers the turn ended without echoing stay visible but unconfirmed: no
      // echo means we cannot tell consumed from dropped, so there is no
      // "dropped" note. Pending 'steer' is defensive (sendNote emits
      // 'steer-pending'), but catch it so a never-echoed steer can never read
      // as confirmed.
      for (var i = 0; i < d.items.length; i++) {
        final it = d.items[i];
        if (it is UserItem &&
            it.pending &&
            (it.note == 'steer-pending' || it.note == 'steer')) {
          d.items[i] = it.copyWith(
            pending: false,
            stale: true,
            note: 'steer-pending',
          );
        }
      }
      return _close(d);
    case 'session_settled':
      if (!state.items.any((it) => it is UserItem && it.pending)) return state;
      final d = _open(state);
      final next = [
        for (final it in d.items)
          if (it is UserItem && it.pending)
            (it.note == 'steer-pending' || it.note == 'steer')
                ? it.copyWith(
                    pending: false,
                    stale: true,
                    note: 'steer-pending',
                  )
                : it.copyWith(pending: false)
          else
            it,
      ];
      d.items
        ..clear()
        ..addAll(next);
      return _close(d);
    case 'prompt_result':
      if (!event.agentInvokedFalse) return state;
      final i = state.items.indexWhere(
        (it) => it is UserItem && it.pending && it.text.trim().startsWith('/'),
      );
      if (i < 0) return state;
      final d = _open(state);
      d.items[i] = (d.items[i] as UserItem).copyWith(pending: false);
      return _close(d);
    case 'message_start':
    case 'message_update':
    case 'message_end':
      final m =
          event.message ??
          (event.type == 'message_update' ? event.partialMessage : null);
      if (m == null) return state;
      final ame = event.type == 'message_update'
          ? event.assistantMessageEvent
          : null;
      final ameType = strOf(ame ?? const {}, 'type');
      final d = _open(state);
      _applyMessage(
        d,
        m,
        ctx,
        messageId: event.messageId,
        ending: event.type == 'message_end',
        thinkingStreaming:
            ameType != null &&
            ameType.startsWith('thinking_') &&
            ameType != 'thinking_end',
        fallback: 'anon',
      );
      return _close(d);
    case 'tool_execution_start':
      final d = _open(state);
      _upsertTool(d, (
        id: event.toolCallId ?? '',
        name: event.toolName,
        args: event.args,
        intent: event.intent,
        messageKey: null,
        output: null,
        status: null,
        details: null,
        startedAt: at,
        endedAt: null,
        call: null,
        result: null,
      ));
      return _close(d);
    case 'tool_execution_update':
      final d = _open(state);
      _upsertTool(d, (
        id: event.toolCallId ?? '',
        name: event.toolName,
        args: event.args,
        intent: null,
        messageKey: null,
        output: event.raw.containsKey('partialResult')
            ? resultText(event.partialResult)
            : null,
        status: null,
        details: null,
        startedAt: at,
        endedAt: null,
        call: null,
        result: null,
      ));
      return _close(d);
    case 'tool_execution_end':
      final d = _open(state);
      _upsertTool(d, (
        id: event.toolCallId ?? '',
        name: event.toolName,
        args: null,
        intent: null,
        messageKey: null,
        output: resultText(event.result),
        status: event.isError ? 'error' : 'done',
        details: _rec(event.result)?['details'],
        startedAt: at,
        endedAt: at,
        call: null,
        result: event.result,
      ));
      return _close(d);
    case 'extension_ui_request':
      if (isBlockingUiMap(event.raw)) {
        if (state.pendingUi.any((u) => u.id == (event.raw['id'] ?? ''))) {
          return state;
        }
        final d = _open(state);
        d.pendingUi.add(UiRequest(event.raw));
        return _close(d);
      }
      if (event.raw['method'] == 'notify') {
        // TS: ev.message || ev.title — an empty message falls through to title.
        final message = strOf(event.raw, 'message');
        final text = (message != null && message.isNotEmpty)
            ? message
            : (event.title ?? '');
        final key = 'ui:${event.raw['id'] ?? ''}';
        if (text.isEmpty || state.items.any((it) => it.messageKey == key)) {
          return state;
        }
        final d = _open(state);
        d.items.add(
          NoticeItem(
            id: 'n:$key',
            messageKey: key,
            level: event.notifyType == 'error' ? 'error' : 'info',
            text: text,
          ),
        );
        return _close(d);
      }
      return state;
    case 'ui_resolved':
      final id = event.raw['id'] ?? '';
      if (!state.pendingUi.any((u) => u.id == id)) return state;
      final d = _open(state);
      d.pendingUi.removeWhere((u) => u.id == id);
      return _close(d);
    case 'command_output':
      final d = _open(state);
      final i = d.items.indexWhere(
        (it) => it is UserItem && it.pending && it.text.trim().startsWith('/'),
      );
      final UserItem? typed = i >= 0 ? d.items[i] as UserItem : null;
      final item = CommandItem(
        id: typed?.id ?? _nextId(d, 'c'),
        command: typed?.text.trim(),
        text: event.text ?? '',
        raw: event.raw,
      );
      if (i >= 0) {
        d.items[i] = item;
      } else {
        d.items.add(item);
      }
      return _close(d);
    case 'auto_compaction_start':
      final d = _open(state);
      d.items.add(
        NoticeItem(
          id: _nextId(d, 'n'),
          level: 'info',
          tag: 'compaction',
          active: true,
          text: 'Compacting context',
        ),
      );
      return _close(d);
    case 'auto_compaction_end':
      // TS: ev.errorMessage ? ... — an empty string is absent.
      final hasError =
          event.errorMessage != null && event.errorMessage!.isNotEmpty;
      final text = hasError
          ? 'Compaction failed: ${event.errorMessage}'
          : event.aborted
          ? 'Compaction stopped'
          : 'Context compacted';
      return _closeNotice(
        state,
        'compaction',
        hasError ? 'error' : 'info',
        text,
      );
    case 'auto_retry_start':
      final of = (event.maxAttempts != null && event.maxAttempts != 0)
          ? ' of ${event.maxAttempts}'
          : '';
      final retryError = event.errorMessage;
      final why = (retryError != null && retryError.isNotEmpty)
          ? ': $retryError'
          : '';
      final d = _open(state);
      d.items.add(
        NoticeItem(
          id: _nextId(d, 'n'),
          level: 'info',
          tag: 'retry',
          active: true,
          text: 'Retrying, attempt ${event.attempt ?? 1}$of$why',
        ),
      );
      return _close(d);
    case 'auto_retry_end':
      return event.success
          ? _closeNotice(state, 'retry', 'info', 'Recovered after retry')
          : _closeNotice(
              state,
              'retry',
              'error',
              (event.finalError != null && event.finalError!.isNotEmpty)
                  ? 'Gave up retrying: ${event.finalError!}'
                  : 'Gave up retrying',
            );
    case 'model_changed':
      final name = _modelName(event.raw['model']);
      return name != null ? _pushNotice(state, 'info', 'Model: $name') : state;
    case 'thinking_level_changed':
      final level = event.raw['level'] ?? event.thinkingLevel;
      return level is String && level.isNotEmpty
          ? _pushNotice(state, 'info', 'Thinking: $level')
          : state;
    case 'notice':
      final text = event.raw['message'] ?? event.text;
      return text is String && text.isNotEmpty
          ? _pushNotice(state, event.level == 'error' ? 'error' : 'info', text)
          : state;
    case 'extension_error':
      return _pushNotice(
        state,
        'error',
        'Extension error: ${event.error ?? 'unknown'}',
      );
    default:
      // Unknown event types are ignored: omp adds them.
      return state;
  }
}

String? _modelName(Object? m) {
  if (m == null) return null;
  if (m is String) return m;
  final o = _rec(m);
  if (o == null) return null;
  final name = o['name'];
  final id = o['id'];
  if (name is String && name.isNotEmpty) return name;
  if (id is String) return id;
  return null;
}

TranscriptState _pushNotice(TranscriptState state, String level, String text) {
  final d = _open(state);
  d.items.add(NoticeItem(id: _nextId(d, 'n'), level: level, text: text));
  return _close(d);
}

TranscriptState _closeNotice(
  TranscriptState state,
  String tag,
  String level,
  String text,
) {
  final d = _open(state);
  for (var i = d.items.length - 1; i >= 0; i--) {
    final it = d.items[i];
    if (it is NoticeItem && it.tag == tag && it.active == true) {
      d.items[i] = it.copyWith(level: level, text: text, active: false);
      return _close(d);
    }
  }
  d.items.add(
    NoticeItem(id: _nextId(d, 'n'), level: level, text: text, tag: tag),
  );
  return _close(d);
}
