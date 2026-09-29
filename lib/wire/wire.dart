// Wire accessors for the omp gateway protocol. The gateway passes omp's
// events through untouched, so anything omp adds later shows up as an unknown
// event type or an unknown field and must be ignored, never thrown on.
//
// Messages, content blocks and events are kept as `Map<String, Object?>` at
// the boundary; these accessors are the only place `dynamic` narrowing
// happens. `null` for a missing or wrong-typed field, like optional fields
// in the TypeScript types.

/// Read a String field, null when missing or not a String.
String? strOf(Map<String, Object?> m, String k) => m[k] is String ? m[k] as String : null;

/// Read a number field as int, null when missing or not a number.
int? intOf(Map<String, Object?> m, String k) => m[k] is num ? (m[k] as num).toInt() : null;

/// Read a bool field, null when missing or not a bool.
bool? boolOf(Map<String, Object?> m, String k) => m[k] is bool ? m[k] as bool : null;

/// Read an object field, null when missing, not a Map, or an array.
Map<String, Object?>? mapOf(Object? v) =>
    v is Map<String, Object?> ? v : (v is Map ? v.cast<String, Object?>() : null);

Map<String, Object?>? mapField(Map<String, Object?> m, String k) => mapOf(m[k]);

/// Read an array field, null when missing or not a List.
List<Object?>? listOf(Object? v) => v is List<Object?> ? v : (v is List ? v.cast<Object?>() : null);

List<Object?>? listField(Map<String, Object?> m, String k) => listOf(m[k]);

// ------------------------------------------------------------- content blocks

/// A `toolCall` content block (id, name, arguments, optional intent).
class ToolCallBlock {
  final String id;
  final String name;
  final Map<String, Object?>? arguments;
  final String? intent;

  const ToolCallBlock({required this.id, required this.name, this.arguments, this.intent});

  static ToolCallBlock? from(Object? b) {
    final m = mapOf(b);
    if (m == null) return null;
    if (m['type'] != 'toolCall') return null;
    final id = strOf(m, 'id');
    final name = strOf(m, 'name');
    if (id == null || name == null) return null;
    return ToolCallBlock(
      id: id,
      name: name,
      arguments: mapField(m, 'arguments'),
      intent: strOf(m, 'intent'),
    );
  }
}

// ------------------------------------------------------------------- messages

/// Roles of the omp messages the transcript reducer consumes.
bool isRole(Map<String, Object?> m, String role) => m['role'] == role;

Object? messageContent(Map<String, Object?> m) => m['content'];

int? messageTimestamp(Map<String, Object?> m) => intOf(m, 'timestamp');

/// True when this user message is a steer the agent picked up mid-turn.
bool messageSteering(Map<String, Object?> m) => m['steering'] == true;

/// Custom messages with display:false are never shown.
bool messageDisplay(Map<String, Object?> m) => m['display'] != false;

String? messageCustomType(Map<String, Object?> m) => strOf(m, 'customType');

Map<String, Object?>? messageDetails(Map<String, Object?> m) => mapField(m, 'details');

bool messageIsError(Map<String, Object?> m) => m['isError'] == true;

String? messageToolCallId(Map<String, Object?> m) => strOf(m, 'toolCallId');

String? messageToolName(Map<String, Object?> m) => strOf(m, 'toolName');

// ------------------------------------------------------------------ UiRequest

const blockingUiMethods = {'select', 'confirm', 'input', 'editor'};

/// One extension dialog. `raw` keeps the whole request for the answer call.
class UiRequest {
  final Map<String, Object?> raw;

  const UiRequest(this.raw);

  String get id => strOf(raw, 'id') ?? '';
  String get method => strOf(raw, 'method') ?? '';
  String? get title => strOf(raw, 'title');
  String? get message => strOf(raw, 'message');
  List<Object?>? get options => listField(raw, 'options');
  String? get placeholder => strOf(raw, 'placeholder');
  String? get prefill => strOf(raw, 'prefill');
  String? get text => strOf(raw, 'text');
  int? get timeout => intOf(raw, 'timeout');

  /// Blocking dialog methods are answered by the user; the rest are fire-and-forget.
  bool get isBlocking => blockingUiMethods.contains(method);

  static UiRequest? from(Object? v) {
    final m = mapOf(v);
    return m == null ? null : UiRequest(m);
  }

  @override
  bool operator ==(Object other) => other is UiRequest && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'UiRequest(${raw.toString()})';
}

/// Blocking dialog methods answered by the user; the rest are fire-and-forget.
bool isBlockingUi(UiRequest u) => u.isBlocking;

/// Map-level form used when the request has not been wrapped yet.
bool isBlockingUiMap(Map<String, Object?> ui) => blockingUiMethods.contains(ui['method']);

// --------------------------------------------------------------------- events

/// One omp event, tagged by `type`. Unknown types are wrapped too and the
/// reducer ignores them.
class OmpEvent {
  final Map<String, Object?> raw;

  const OmpEvent(this.raw);

  String get type => strOf(raw, 'type') ?? '';

  String? get messageId => strOf(raw, 'messageId');

  /// The whole message carried by message_start / message_end (and usually
  /// message_update).
  Map<String, Object?>? get message => mapField(raw, 'message');

  /// The streaming sub-event of a message_update.
  Map<String, Object?>? get assistantMessageEvent => mapField(raw, 'assistantMessageEvent');

  /// message_update fallback: the partial assistant message so far.
  Map<String, Object?>? get partialMessage {
    final ame = assistantMessageEvent;
    return ame == null ? null : mapField(ame, 'partial');
  }

  String? get toolCallId => strOf(raw, 'toolCallId');
  String? get toolName => strOf(raw, 'toolName');
  Object? get args => raw['args'];
  String? get intent => strOf(raw, 'intent');
  Object? get partialResult => raw['partialResult'];
  Object? get result => raw['result'];
  bool get isError => raw['isError'] == true;
  String? get text => strOf(raw, 'text');
  String? get title => strOf(raw, 'title');
  String? get level => strOf(raw, 'level');
  int? get attempt => intOf(raw, 'attempt');
  int? get maxAttempts => intOf(raw, 'maxAttempts');
  String? get errorMessage => strOf(raw, 'errorMessage');
  String? get finalError => strOf(raw, 'finalError');
  bool get success => raw['success'] == true;
  bool get aborted => raw['aborted'] == true;
  String? get error => strOf(raw, 'error');
  String? get thinkingLevel => strOf(raw, 'thinkingLevel');
  String? get notifyType => strOf(raw, 'notifyType');

  /// prompt_result with agentInvoked === false means a slash command ran
  /// without the agent.
  bool get agentInvokedFalse => raw['agentInvoked'] == false;

  @override
  String toString() => 'OmpEvent(${raw.toString()})';
}
