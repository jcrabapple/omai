// Slash menu: which text opens it, fuzzy filtering, grouping by source.
// Ported from web/src/lib/composer/slash.ts. Pure Dart, no Flutter imports.

/// `builtin` | `skill` | `extension` | `custom` | `file` (tolerant: unknown
/// sources group under `custom`, matching the web's `GROUP_OF` fallback).
typedef SlashSource = String;

/// One slash command as the gateway reports it (GET /sessions/{id}/commands
/// and `available_commands_update`). Tolerant parse: missing optional fields
/// stay null, wrong-typed fields are ignored.
class SlashCommand {
  final String name;
  final String description;
  final SlashSource source;
  final List<String> aliases;
  final String? inputHint;
  final List<SlashCommandSub> subcommands;

  const SlashCommand({
    required this.name,
    this.description = '',
    this.source = 'custom',
    this.aliases = const [],
    this.inputHint,
    this.subcommands = const [],
  });

  static SlashCommand? from(Object? v) {
    if (v is! Map) return null;
    final m = v.cast<String, Object?>();
    final name = m['name'];
    if (name is! String || name.isEmpty) return null;
    final aliases = <String>[];
    final rawAliases = m['aliases'];
    if (rawAliases is List) {
      for (final a in rawAliases) {
        if (a is String) aliases.add(a);
      }
    }
    String? inputHint;
    final input = m['input'];
    if (input is Map) {
      final hint = input['hint'];
      if (hint is String) inputHint = hint;
    }
    final subs = <SlashCommandSub>[];
    final rawSubs = m['subcommands'];
    if (rawSubs is List) {
      for (final s in rawSubs) {
        final sub = SlashCommandSub.from(s);
        if (sub != null) subs.add(sub);
      }
    }
    return SlashCommand(
      name: name,
      description: m['description'] is String ? m['description'] as String : '',
      source: m['source'] is String ? m['source'] as String : 'custom',
      aliases: aliases,
      inputHint: inputHint,
      subcommands: subs,
    );
  }

  static List<SlashCommand> listFrom(Object? v) {
    if (v is! List) return const [];
    return [
      for (final c in v)
        if (SlashCommand.from(c) != null) SlashCommand.from(c)!,
    ];
  }

  @override
  bool operator ==(Object other) => other is SlashCommand && other.name == name && other.source == source;

  @override
  int get hashCode => Object.hash(name, source);
}

class SlashCommandSub {
  final String name;
  final String? description;
  const SlashCommandSub({required this.name, this.description});

  static SlashCommandSub? from(Object? v) {
    if (v is! Map) return null;
    final name = v['name'];
    if (name is! String) return null;
    return SlashCommandSub(
      name: name,
      description: v['description'] is String ? v['description'] as String : null,
    );
  }
}

typedef SlashGroupKey = String; // 'commands' | 'skills' | 'extensions' | 'custom'

class SlashMatch {
  final SlashCommand command;
  final int score;
  const SlashMatch(this.command, this.score);
}

class SlashGroup {
  final SlashGroupKey key;
  final String label;
  final List<SlashMatch> items;
  const SlashGroup(this.key, this.label, this.items);
}

const _groups = <(SlashGroupKey, String)>[
  ('commands', 'Commands'),
  ('skills', 'Skills'),
  ('extensions', 'Extensions'),
  ('custom', 'Custom'),
];

SlashGroupKey _groupOf(SlashSource source) {
  switch (source) {
    case 'builtin':
      return 'commands';
    case 'skill':
      return 'skills';
    case 'extension':
      return 'extensions';
    default:
      return 'custom'; // custom, file, anything new
  }
}

/// The query after the slash when the whole draft is still one slash token,
/// else null.
String? slashQuery(String text) {
  if (!text.startsWith('/')) return null;
  final rest = text.substring(1);
  return rest.contains(RegExp(r'\s')) ? null : rest;
}

String firstDescriptionLine(SlashCommand cmd) {
  final i = cmd.description.indexOf('\n');
  return (i < 0 ? cmd.description : cmd.description.substring(0, i)).trim();
}

int _subsequenceScore(String needle, String hay) {
  var at = -1;
  var gaps = 0;
  for (final ch in needle.split('')) {
    final next = hay.indexOf(ch, at + 1);
    if (next < 0) return -1;
    if (at >= 0) gaps += next - at - 1;
    at = next;
  }
  return 200 - gaps < 1 ? 1 : 200 - gaps;
}

String _escapeRe(String s) => s.replaceAllMapped(
    RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m.input.substring(m.start, m.end)}');

int scoreCommand(SlashCommand cmd, String rawQuery) {
  final q = rawQuery.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final name = cmd.name.toLowerCase();
  // `skill:humanizer` should match "hum" as well as "skill:hum".
  final colon = name.indexOf(':');
  final bare = colon >= 0 ? name.substring(colon + 1) : name;
  if (name == q || bare == q) return 1000;
  if (name.startsWith(q)) return 800 - (name.length - q.length);
  if (bare.startsWith(q)) return 760 - (bare.length - q.length);
  for (final a in cmd.aliases) {
    if (a.toLowerCase().startsWith(q)) return 700;
  }
  if (RegExp('[-:_/.]${_escapeRe(q)}').hasMatch(name)) return 500;
  if (name.contains(q)) return 400;
  final sub = _subsequenceScore(q, name);
  if (sub > 0) return sub;
  if (firstDescriptionLine(cmd).toLowerCase().contains(q)) return 100;
  return -1;
}

List<SlashGroup> filterCommands(List<SlashCommand> commands, String query) {
  final buckets = <SlashGroupKey, List<SlashMatch>>{};
  for (final command in commands) {
    final score = scoreCommand(command, query);
    if (score < 0) continue;
    final key = _groupOf(command.source);
    buckets.putIfAbsent(key, () => []).add(SlashMatch(command, score));
  }
  final out = <SlashGroup>[];
  for (final (key, label) in _groups) {
    final items = buckets[key];
    if (items == null || items.isEmpty) continue;
    items.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.command.name.toLowerCase().compareTo(b.command.name.toLowerCase());
    });
    out.add(SlashGroup(key, label, items));
  }
  return out;
}

/// Keyboard order: the groups top to bottom.
List<SlashMatch> flattenGroups(List<SlashGroup> groups) =>
    [for (final g in groups) ...g.items];

/// True when the command wants arguments, so selecting it should insert
/// rather than send.
bool wantsInput(SlashCommand cmd) =>
    (cmd.inputHint?.isNotEmpty ?? false) || cmd.subcommands.isNotEmpty;

String slashText(SlashCommand cmd) => '/${cmd.name} ';
