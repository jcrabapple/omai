// Wire models for the gateway REST API, ported from web/src/lib/api/types.ts.
// Tolerant parsing: unknown fields ignored, missing optional fields null.
// No Flutter imports; `dynamic` only at the JSON boundary, narrowed by the
// small accessors below.

import '../format.dart';

/// Narrow typed accessors over a decoded JSON map.
Map<String, dynamic>? asMap(Object? v) => v is Map<String, dynamic> ? v : null;
List<Object?>? asList(Object? v) => v is List<Object?> ? v : null;

String? str(Object? v) => v is String ? v : null;
int? intVal(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
double? dbl(Object? v) => v is num ? v.toDouble() : null;
bool? boolVal(Object? v) => v is bool ? v : null;

/// Unknown / future fields on dialogs stay raw until C's UiRequest lands.
List<Map<String, Object?>> rawMapList(Object? v) {
  final list = asList(v) ?? const [];
  return [
    for (final e in list)
      if (asMap(e) != null)
        Map<String, Object?>.from(e as Map<String, dynamic>),
  ];
}

class ModelCost {
  const ModelCost({
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
  });

  factory ModelCost.fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    return ModelCost(
      input: dbl(m['input']) ?? 0,
      output: dbl(m['output']) ?? 0,
      cacheRead: dbl(m['cacheRead']) ?? 0,
      cacheWrite: dbl(m['cacheWrite']) ?? 0,
    );
  }

  final double input;
  final double output;
  final double cacheRead;
  final double cacheWrite;
}

class ContextUsage {
  const ContextUsage({
    required this.tokens,
    required this.contextWindow,
    required this.percent,
  });

  factory ContextUsage.fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    return ContextUsage(
      tokens: intVal(m['tokens']),
      contextWindow: intVal(m['contextWindow']) ?? 0,
      percent: dbl(m['percent']),
    );
  }

  final int? tokens;
  final int contextWindow;
  final double? percent;
}

/// Model as reported inside session info (subset the app renders; unknown
/// fields such as `compat` are ignored).
class ModelRef {
  const ModelRef({
    required this.id,
    required this.provider,
    this.name,
    this.reasoning,
    this.contextWindow,
    this.maxTokens,
  });

  factory ModelRef.fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    return ModelRef(
      id: str(m['id']) ?? '',
      provider: str(m['provider']) ?? '',
      name: str(m['name']),
      reasoning: boolVal(m['reasoning']),
      contextWindow: intVal(m['contextWindow']),
      maxTokens: intVal(m['maxTokens']),
    );
  }

  final String id;
  final String provider;
  final String? name;
  final bool? reasoning;
  final int? contextWindow;
  final int? maxTokens;

  String get displayName => name ?? id;
}

/// Session info as returned by `GET /api/sessions/{id}` and the WS auth_ok.
class SessionInfo {
  const SessionInfo({
    required this.gwId,
    required this.cwd,
    required this.approvalMode,
    required this.resumedFrom,
    required this.ompSessionId,
    required this.ompSessionFile,
    required this.ompSessionName,
    required this.model,
    required this.thinkingLevel,
    this.advisor = false,
    required this.isStreaming,
    required this.idleSec,
    required this.exited,
    required this.exitCode,
    required this.protocolVersion,
    required this.uptimeSec,
    required this.subscribers,
    required this.messageCount,
    required this.contextUsage,
    required this.lastEventSeq,
    required this.pendingUi,
    this.alreadyLive = false,
    this.cwdFallback = false,
  });

  factory SessionInfo.fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    return SessionInfo(
      gwId: str(m['gwId']) ?? '',
      cwd: str(m['cwd']) ?? '',
      approvalMode: str(m['approvalMode']) ?? 'yolo',
      resumedFrom: str(m['resumedFrom']),
      ompSessionId: str(m['ompSessionId']),
      ompSessionFile: str(m['ompSessionFile']),
      ompSessionName: str(m['ompSessionName']),
      model: asMap(m['model']) == null ? null : ModelRef.fromJson(m['model']),
      thinkingLevel: str(m['thinkingLevel']),
      // Missing on gateways older than the advisor launch flag: treat as off.
      advisor: boolVal(m['advisor']) ?? false,
      isStreaming: boolVal(m['isStreaming']) ?? false,
      idleSec: dbl(m['idleSec']) ?? 0,
      exited: boolVal(m['exited']) ?? false,
      exitCode: intVal(m['exitCode']),
      protocolVersion: intVal(m['protocolVersion']),
      uptimeSec: dbl(m['uptimeSec']) ?? 0,
      subscribers: intVal(m['subscribers']) ?? 0,
      messageCount: intVal(m['messageCount']) ?? 0,
      contextUsage: asMap(m['contextUsage']) == null
          ? null
          : ContextUsage.fromJson(m['contextUsage']),
      lastEventSeq: intVal(m['lastEventSeq']) ?? 0,
      pendingUi: rawMapList(m['pendingUi']),
      alreadyLive: boolVal(m['alreadyLive']) ?? false,
      cwdFallback: boolVal(m['cwdFallback']) ?? false,
    );
  }

  final String gwId;
  final String cwd;
  final String approvalMode;
  final String? resumedFrom;
  final String? ompSessionId;
  final String? ompSessionFile;
  final String? ompSessionName;
  final ModelRef? model;
  final String? thinkingLevel;

  /// omp's advisor runtime (reviews each turn, injects notes). Launch-time
  /// only: set on POST /sessions, carried through forks, never toggled live.
  final bool advisor;
  final bool isStreaming;
  final double idleSec;
  final bool exited;
  final int? exitCode;
  final int? protocolVersion;
  final double uptimeSec;
  final int subscribers;
  final int messageCount;
  final ContextUsage? contextUsage;
  final int lastEventSeq;
  final List<Map<String, Object?>> pendingUi;

  /// Flags on `POST /api/sessions` responses only.
  final bool alreadyLive;
  final bool cwdFallback;

  /// Title shown in lists, ported from web/src/lib/format.ts sessionTitle:
  /// the trimmed session name, else the cwd basename, else 'Session'. The
  /// gateway can report ompSessionName as '' or whitespace when no name was
  /// set.
  String get title {
    final name = ompSessionName?.trim() ?? '';
    if (name.isNotEmpty) return name;
    return basename(cwd).isEmpty ? 'Session' : basename(cwd);
  }
}

/// A transcript on disk that can be resumed. `cwd` is null for older files;
/// prefer it over the mangled `cwdFolder` for display.
class SavedSession {
  const SavedSession({
    required this.file,
    required this.mtime,
    required this.sizeBytes,
    required this.cwdFolder,
    required this.cwd,
    this.cwdExists,
    required this.title,
    required this.running,
  });

  factory SavedSession.fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    return SavedSession(
      file: str(m['file']) ?? '',
      mtime: dbl(m['mtime']) ?? 0,
      sizeBytes: intVal(m['sizeBytes']) ?? 0,
      cwdFolder: str(m['cwdFolder']) ?? '',
      cwd: str(m['cwd']),
      cwdExists: boolVal(m['cwdExists']),
      title: str(m['title']) ?? '',
      running: boolVal(m['running']) ?? false,
    );
  }

  final String file;
  final double mtime;
  final int sizeBytes;
  final String cwdFolder;
  final String? cwd;

  /// Whether [cwd] still exists on the gateway host. Null when unknown: no
  /// cwd recorded, or a gateway older than the field (docs/API.md).
  final bool? cwdExists;
  final String title;
  final bool running;

  String get displayCwd => cwd ?? cwdFolder;
}

/// Port of web/src/lib/format.ts savedFolderLabel: the real cwd's basename
/// when the transcript has one, else the live session whose mangled cwd ends
/// with the folder, else the folder with its leading dashes stripped.
String savedFolderLabel(SavedSession saved, List<String> liveCwds) {
  final cwd = saved.cwd;
  if (cwd != null && cwd.isNotEmpty) {
    final base = basename(cwd);
    return base.isEmpty ? cwd : base;
  }
  final folder = saved.cwdFolder;
  for (final liveCwd in liveCwds) {
    if (folder.isNotEmpty && liveCwd.replaceAll('/', '-').endsWith(folder)) {
      return basename(liveCwd);
    }
  }
  final unmangled = folder.replaceFirst(RegExp(r'^-+'), '');
  return unmangled.isEmpty ? 'session' : unmangled;
}

// Port of web/src/lib/format.ts savedTitle (null-safe after gateway commit
// ecc5752): a null/empty/whitespace title falls back to the folder label, so
// a session with no prompt snippet never renders as an empty row.
String savedTitle(SavedSession saved, List<String> liveCwds) {
  final title = saved.title.trim();
  return title.isNotEmpty ? title : savedFolderLabel(saved, liveCwds);
}

/// `GET /api/sessions` -> `{live: [...], saved: [...]}`.
class SessionsList {
  const SessionsList({required this.live, required this.saved});

  factory SessionsList.fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    final live = asList(m['live']) ?? const [];
    final saved = asList(m['saved']) ?? const [];
    return SessionsList(
      live: [
        for (final e in live)
          if (asMap(e) != null) SessionInfo.fromJson(e),
      ],
      saved: [
        for (final e in saved)
          if (asMap(e) != null) SavedSession.fromJson(e),
      ],
    );
  }

  final List<SessionInfo> live;
  final List<SavedSession> saved;
}

/// Model as emitted by `omp models --json` (GET /api/catalog/models).
class CatalogModel {
  const CatalogModel({
    required this.provider,
    required this.id,
    required this.selector,
    required this.name,
    required this.contextWindow,
    required this.maxTokens,
    required this.reasoning,
    required this.thinking,
    required this.input,
    required this.cost,
  });

  factory CatalogModel.fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    final thinking = asList(m['thinking']);
    final input = asList(m['input']) ?? const [];
    return CatalogModel(
      provider: str(m['provider']) ?? '',
      id: str(m['id']) ?? '',
      selector: str(m['selector']) ?? '',
      name: str(m['name']) ?? '',
      contextWindow: intVal(m['contextWindow']) ?? 0,
      maxTokens: intVal(m['maxTokens']) ?? 0,
      reasoning: boolVal(m['reasoning']) ?? false,
      thinking: thinking == null
          ? null
          : [for (final t in thinking) str(t) ?? ''],
      input: [for (final t in input) str(t) ?? ''],
      cost: ModelCost.fromJson(m['cost']),
    );
  }

  final String provider;
  final String id;
  final String selector;
  final String name;
  final int contextWindow;
  final int maxTokens;
  final bool reasoning;
  final List<String>? thinking;
  final List<String> input;
  final ModelCost cost;

  String get label => '$provider/$id';
}

class CatalogModels {
  const CatalogModels({required this.models});

  factory CatalogModels.fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    final list = asList(m['models']) ?? const [];
    return CatalogModels(
      models: [
        for (final e in list)
          if (asMap(e) != null) CatalogModel.fromJson(e),
      ],
    );
  }

  final List<CatalogModel> models;
}
