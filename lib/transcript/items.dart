// Immutable transcript items, ported from web/src/lib/transcript/types.ts.
// `raw` keeps the latest source object for the inspector and is never compared
// in tests; `normalized()` mirrors the web tests' normalize() (drops raw,
// startedAt, endedAt, note and details), so history and live items for the
// same turn compare equal.
import 'diff.dart';

sealed class Item {
  /// Stable across history and live for keyed items.
  final String id;

  /// Cross-source message key (`role:timestamp`, or `role:id:<messageId>`).
  final String? messageKey;

  /// Latest source object, for the inspector. Not compared in tests.
  final Object? raw;

  const Item({required this.id, this.messageKey, this.raw});

  String get kind;

  /// Comparable view of the item ignoring `raw` and timing fields.
  Map<String, Object?> normalized();
}

typedef UserNote =
    String; // 'steer' | 'steer-pending' | 'queued' | 'other-client'

class UserItem extends Item {
  final String text;
  final int images;

  /// True from local send until the echo arrives (or the session settles).
  final bool pending;
  final UserNote? note;

  /// A steer sent mid-turn that never got its echo.
  final bool? stale;
  final bool? failed;
  final String? error;
  final int? timestamp;

  /// Local sends only: the id the caller passed to local-send.
  final String? localId;

  const UserItem({
    required super.id,
    required this.text,
    required this.images,
    required this.pending,
    this.note,
    this.stale,
    this.failed,
    this.error,
    this.timestamp,
    this.localId,
    super.messageKey,
    super.raw,
  });

  @override
  String get kind => 'user';

  UserItem copyWith({
    String? id,
    String? text,
    int? images,
    bool? pending,
    UserNote? note,
    bool clearNote = false,
    bool? stale,
    bool? failed,
    String? error,
    bool clearError = false,
    int? timestamp,
    bool clearTimestamp = false,
    String? localId,
    bool clearLocalId = false,
    String? messageKey,
    bool clearMessageKey = false,
    Object? raw,
    bool clearRaw = false,
  }) => UserItem(
    id: id ?? this.id,
    text: text ?? this.text,
    images: images ?? this.images,
    pending: pending ?? this.pending,
    note: clearNote ? null : (note ?? this.note),
    stale: stale ?? this.stale,
    failed: failed ?? this.failed,
    error: clearError ? null : (error ?? this.error),
    timestamp: clearTimestamp ? null : (timestamp ?? this.timestamp),
    localId: clearLocalId ? null : (localId ?? this.localId),
    messageKey: clearMessageKey ? null : (messageKey ?? this.messageKey),
    raw: clearRaw ? null : (raw ?? this.raw),
  );

  @override
  Map<String, Object?> normalized() => {
    'kind': kind,
    'id': id,
    if (messageKey != null) 'messageKey': messageKey,
    'text': text,
    'images': images,
    'pending': pending,
    if (stale != null) 'stale': stale,
    if (failed != null) 'failed': failed,
    if (error != null) 'error': error,
    if (timestamp != null) 'timestamp': timestamp,
    if (localId != null) 'localId': localId,
  };
}

class AssistantItem extends Item {
  final String text;
  final bool streaming;
  final String? model;
  final String? provider;
  final Map<String, Object?>? usage;
  final String? stopReason;
  final String? error;
  final int? timestamp;

  /// Milliseconds, from message_end.
  final int? duration;
  final int? ttft;

  const AssistantItem({
    required super.id,
    required this.text,
    required this.streaming,
    this.model,
    this.provider,
    this.usage,
    this.stopReason,
    this.error,
    this.timestamp,
    this.duration,
    this.ttft,
    super.messageKey,
    super.raw,
  });

  @override
  String get kind => 'assistant';

  AssistantItem copyWith({bool? streaming}) => AssistantItem(
    id: id,
    text: text,
    streaming: streaming ?? this.streaming,
    model: model,
    provider: provider,
    usage: usage,
    stopReason: stopReason,
    error: error,
    timestamp: timestamp,
    duration: duration,
    ttft: ttft,
    messageKey: messageKey,
    raw: raw,
  );

  @override
  Map<String, Object?> normalized() => {
    'kind': kind,
    'id': id,
    if (messageKey != null) 'messageKey': messageKey,
    'text': text,
    'streaming': streaming,
    if (model != null) 'model': model,
    if (provider != null) 'provider': provider,
    if (usage != null) 'usage': usage,
    if (stopReason != null) 'stopReason': stopReason,
    if (error != null) 'error': error,
    if (timestamp != null) 'timestamp': timestamp,
    if (duration != null) 'duration': duration,
    if (ttft != null) 'ttft': ttft,
  };
}

class ThinkingItem extends Item {
  final String text;
  final bool streaming;

  /// Live: when we first saw it. History: the assistant message timestamp.
  final int? startedAt;

  /// Live only. History has no thinking timing.
  final int? endedAt;

  const ThinkingItem({
    required super.id,
    required this.text,
    required this.streaming,
    this.startedAt,
    this.endedAt,
    super.messageKey,
    super.raw,
  });

  @override
  String get kind => 'thinking';

  ThinkingItem copyWith({
    bool? streaming,
    int? startedAt,
    bool clearStartedAt = false,
    int? endedAt,
    bool clearEndedAt = false,
  }) => ThinkingItem(
    id: id,
    text: text,
    streaming: streaming ?? this.streaming,
    startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
    endedAt: clearEndedAt ? null : (endedAt ?? this.endedAt),
    messageKey: messageKey,
    raw: raw,
  );

  @override
  Map<String, Object?> normalized() => {
    'kind': kind,
    'id': id,
    if (messageKey != null) 'messageKey': messageKey,
    'text': text,
    'streaming': streaming,
  };
}

typedef ToolStatus = String; // 'running' | 'done' | 'error' | 'interrupted'

class ToolItem extends Item {
  final String toolCallId;
  final String toolName;

  /// Arguments with omp's `i` (intent) key removed.
  final Map<String, Object?>? args;

  /// intent, else command, path, file_path, pattern, query, url, else compact JSON.
  final String summary;
  final String? intent;
  final String output;
  final ToolStatus status;
  final Object? details;

  /// Files this tool changed; empty/absent for other tools.
  final List<FileChange>? files;
  final int? startedAt;
  final int? endedAt;

  const ToolItem({
    required super.id,
    required this.toolCallId,
    required this.toolName,
    required this.summary,
    required this.output,
    required this.status,
    this.args,
    this.intent,
    this.details,
    this.files,
    this.startedAt,
    this.endedAt,
    super.messageKey,
    super.raw,
  });

  @override
  String get kind => 'tool';

  ToolItem copyWith({
    ToolStatus? status,
    Object? details,
    bool clearDetails = false,
    List<FileChange>? files,
    bool clearFiles = false,
    String? messageKey,
    bool clearMessageKey = false,
    Object? raw,
    bool clearRaw = false,
  }) => ToolItem(
    id: id,
    toolCallId: toolCallId,
    toolName: toolName,
    args: args,
    summary: summary,
    intent: intent,
    output: output,
    status: status ?? this.status,
    details: clearDetails ? null : (details ?? this.details),
    files: clearFiles ? null : (files ?? this.files),
    startedAt: startedAt,
    endedAt: endedAt,
    messageKey: clearMessageKey ? null : (messageKey ?? this.messageKey),
    raw: clearRaw ? null : (raw ?? this.raw),
  );

  @override
  Map<String, Object?> normalized() => {
    'kind': kind,
    'id': id,
    if (messageKey != null) 'messageKey': messageKey,
    'toolCallId': toolCallId,
    'toolName': toolName,
    if (args != null) 'args': args,
    'summary': summary,
    if (intent != null) 'intent': intent,
    'output': output,
    'status': status,
    if (files != null) 'files': files,
  };
}

class SkillItem extends Item {
  final String name;

  /// Full injected prompt, for the expander.
  final String content;
  final String? prompt;
  final int? lineCount;
  final int? timestamp;

  const SkillItem({
    required super.id,
    required this.name,
    required this.content,
    this.prompt,
    this.lineCount,
    this.timestamp,
    super.messageKey,
    super.raw,
  });

  @override
  String get kind => 'skill';

  @override
  Map<String, Object?> normalized() => {
    'kind': kind,
    'id': id,
    if (messageKey != null) 'messageKey': messageKey,
    'name': name,
    'content': content,
    if (prompt != null) 'prompt': prompt,
    if (lineCount != null) 'lineCount': lineCount,
    if (timestamp != null) 'timestamp': timestamp,
  };
}

class CommandItem extends Item {
  /// What the user typed, when we know it.
  final String? command;

  /// Raw output, ANSI SGR codes intact.
  final String text;

  const CommandItem({
    required super.id,
    required this.text,
    this.command,
    super.messageKey,
    super.raw,
  });

  @override
  String get kind => 'command';

  @override
  Map<String, Object?> normalized() => {
    'kind': kind,
    'id': id,
    if (messageKey != null) 'messageKey': messageKey,
    'text': text,
    if (command != null) 'command': command,
  };
}

typedef NoticeTag = String; // 'compaction' | 'retry'

class NoticeItem extends Item {
  final String level; // 'info' | 'error'
  final String text;
  final NoticeTag? tag;

  /// True while the thing the notice describes is still going on.
  final bool? active;

  const NoticeItem({
    required super.id,
    required this.level,
    required this.text,
    this.tag,
    this.active,
    super.messageKey,
    super.raw,
  });

  @override
  String get kind => 'notice';

  NoticeItem copyWith({
    String? level,
    String? text,
    NoticeTag? tag,
    bool clearTag = false,
    bool? active,
  }) => NoticeItem(
    id: id,
    level: level ?? this.level,
    text: text ?? this.text,
    tag: clearTag ? null : (tag ?? this.tag),
    active: active ?? this.active,
    messageKey: messageKey,
    raw: raw,
  );

  @override
  Map<String, Object?> normalized() => {
    'kind': kind,
    'id': id,
    if (messageKey != null) 'messageKey': messageKey,
    'level': level,
    'text': text,
    if (tag != null) 'tag': tag,
    if (active != null) 'active': active,
  };
}

/// One file attached by an @-mention in the preceding user message. `content`
/// is the text omp attached (null for skipped or image files); it is never
/// put into a semantics label or a log.
class FileMentionFile {
  final String path;
  final String? content;
  final int? lineCount;
  final int? byteSize;

  /// 'tooLarge' | 'binary', as the gateway reports.
  final String? skippedReason;
  final bool image;

  const FileMentionFile({
    required this.path,
    this.content,
    this.lineCount,
    this.byteSize,
    this.skippedReason,
    this.image = false,
  });

  /// File name for the row label (the path goes in the content sheet).
  String get name =>
      path.split('/').where((p) => p.isNotEmpty).lastOrNull ?? path;

  static List<FileMentionFile> listFrom(Object? files) {
    final list = files is List ? files : const [];
    final out = <FileMentionFile>[];
    for (final e in list) {
      if (e is! Map) continue;
      final m = e.cast<String, Object?>();
      final path = m['path'];
      if (path is! String || path.isEmpty) continue;
      out.add(
        FileMentionFile(
          path: path,
          content: m['content'] is String ? m['content'] as String : null,
          lineCount: m['lineCount'] is int ? m['lineCount'] as int : null,
          byteSize: m['byteSize'] is int ? m['byteSize'] as int : null,
          skippedReason: m['skippedReason'] is String
              ? m['skippedReason'] as String
              : null,
          image: m['image'] == true,
        ),
      );
    }
    return out;
  }
}

/// The fileMention message the gateway emits right after a user message whose
/// prompt carried @-tokens: a compact row per attached file under the bubble.
class FileMentionItem extends Item {
  final List<FileMentionFile> files;

  const FileMentionItem({
    required super.id,
    required this.files,
    super.messageKey,
    super.raw,
  });

  @override
  String get kind => 'fileMention';

  @override
  Map<String, Object?> normalized() => {
    'kind': kind,
    'id': id,
    if (messageKey != null) 'messageKey': messageKey,
    'files': [
      for (final f in files)
        {
          'path': f.path,
          if (f.lineCount != null) 'lineCount': f.lineCount,
          if (f.byteSize != null) 'byteSize': f.byteSize,
          if (f.skippedReason != null) 'skippedReason': f.skippedReason,
          if (f.image) 'image': true,
        },
    ],
  };
}
