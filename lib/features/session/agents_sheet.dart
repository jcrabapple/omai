// The agents sheet: one row per background subagent, live from the roster
// (REST snapshot seed + subagent_progress / subagent_lifecycle frames).
// Ported from web/src/components/SubagentPanel.svelte.
//
// Tap a row for that agent's transcript: paged forward through
// /subagents/{sid}/messages with from=nextByte while nextByte is present,
// reset replaces instead of appending, error state offers a retry.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../format.dart' show compactNumber, firstLine, money;
import '../../state/session_controller.dart';
import '../../state/subagents_store.dart';
import '../../theme/tokens.dart';
import '../../transcript/blocks.dart';
import '../../transcript/reducer.dart';
import '../../widgets/transcript_item.dart';

/// Opens the agents sheet as a modal bottom sheet.
Future<void> showAgentsSheet(BuildContext context, String gwId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // A scroll-controlled sheet may grow to full height; without this it
    // slides under the status bar (edge-to-edge is on by default).
    useSafeArea: true,
    builder: (sheetContext) => Material(
      color: Theme.of(sheetContext).extension<OmpTokens>()!.surface,
      child: AgentsSheet(gwId: gwId),
    ),
  );
}

const _statusWord = {
  SubagentStatus.pending: 'Pending',
  SubagentStatus.running: 'Running',
  SubagentStatus.completed: 'Completed',
  SubagentStatus.failed: 'Failed',
  SubagentStatus.aborted: 'Aborted',
};

/// TalkBack label for one row: agent, status, current tool, the first line
/// of the task and the metrics, in one stop.
String rowLabel(SubagentRow row) {
  final bits = <String>[row.agent.isEmpty ? 'Helper' : row.agent];
  bits.add(_statusWord[row.status]!);
  if (row.status == SubagentStatus.running && row.currentTool.isNotEmpty) {
    bits.add(row.currentTool);
  }
  final task = firstLine(row.taskText);
  if (task.isNotEmpty) bits.add(task);
  final metrics = <String>[
    if (row.tokens != null) compactNumber(row.tokens!),
    if (row.cost != null) money(row.cost!),
    if (row.model.isNotEmpty) row.model,
  ];
  if (metrics.isNotEmpty) bits.add(metrics.join(' '));
  return bits.join(', ');
}

class AgentsSheet extends ConsumerWidget {
  const AgentsSheet({super.key, required this.gwId});

  final String gwId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final rows = ref.watch(subagentsStoreProvider);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(OmpMetrics.s3),
              child: Text(
                'Helpers',
                style: TextStyle(
                  color: tokens.ink,
                  fontSize: OmpMetrics.fsLg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OmpMetrics.s3,
                  0,
                  OmpMetrics.s3,
                  OmpMetrics.s4,
                ),
                child: Text(
                  'No helpers in this session.',
                  key: const ValueKey('agents-empty'),
                  style: TextStyle(
                    color: tokens.ink3,
                    fontSize: OmpMetrics.fsSm,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
                  children: [
                    // Newest first: the roster sorts by index to match the
                    // web store; on the phone the last-spawned agent is the
                    // interesting one, so the sheet flips the order.
                    for (final row in rows.reversed)
                      _AgentRowTile(
                        key: ValueKey('agent-row-${row.key}'),
                        gwId: gwId,
                        row: row,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AgentRowTile extends StatelessWidget {
  const _AgentRowTile({super.key, required this.gwId, required this.row});

  final String gwId;
  final SubagentRow row;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final running = row.status == SubagentStatus.running;
    final desc = firstLine(row.taskText);
    final metrics = <String>[
      if (row.tokens != null) compactNumber(row.tokens!),
      if (row.cost != null) money(row.cost!),
      if (row.model.isNotEmpty) row.model,
    ];
    return Semantics(
      button: true,
      label: rowLabel(row),
      excludeSemantics: true,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (context) => SubagentTranscriptPage(
                gwId: gwId,
                rowKey: row.key,
                rowIndex: row.index,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OmpMetrics.s3,
            vertical: OmpMetrics.s2,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 18,
                height: 20,
                child: Center(
                  child: switch (row.status) {
                    SubagentStatus.running => SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: tokens.ink3,
                      ),
                    ),
                    SubagentStatus.completed => Icon(
                      Icons.check,
                      size: 14,
                      color: tokens.ok,
                    ),
                    SubagentStatus.failed => Icon(
                      Icons.close,
                      size: 14,
                      color: tokens.err,
                    ),
                    _ => Container(
                      width: 10,
                      height: 2,
                      decoration: BoxDecoration(
                        color: tokens.ink3,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  },
                ),
              ),
              const SizedBox(width: OmpMetrics.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Line 1: agent name, id when distinct, tool, retry badge.
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            row.agent.isEmpty ? 'Helper' : row.agent,
                            style: TextStyle(
                              color: tokens.ink,
                              fontSize: OmpMetrics.fsBase,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (row.id != null && row.id != row.agent)
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: OmpMetrics.s2,
                              ),
                              child: Text(
                                row.id!,
                                style: TextStyle(
                                  color: tokens.ink3,
                                  fontSize: OmpMetrics.fsXs,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        if (running && row.currentTool.isNotEmpty)
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: OmpMetrics.s2,
                              ),
                              child: Text(
                                row.currentTool,
                                style: TextStyle(
                                  color: tokens.ink3,
                                  fontSize: OmpMetrics.fsXs,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        if (row.retry != null &&
                            row.status != SubagentStatus.completed)
                          Padding(
                            padding: const EdgeInsets.only(left: OmpMetrics.s2),
                            child: Text(
                              'attempt ${row.retry!.attempt}/${row.retry!.maxAttempts}',
                              style: TextStyle(
                                color: tokens.warn,
                                fontSize: OmpMetrics.fsXs,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // Line 2: task text truncates; metrics stay on one line.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            desc.isEmpty ? 'No task text' : desc,
                            style: TextStyle(
                              color: tokens.ink2,
                              fontSize: OmpMetrics.fsSm,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (metrics.isNotEmpty)
                          Flexible(
                            child: Text(
                              metrics.join('  '),
                              style: TextStyle(
                                color: tokens.ink3,
                                fontSize: OmpMetrics.fsXs,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------ transcript page

class _PageState {
  const _PageState({
    required this.messages,
    required this.nextByte,
    required this.loading,
    required this.loadingMore,
    required this.error,
  });

  final List<Map<String, Object?>> messages;
  final int? nextByte;
  final bool loading;
  final bool loadingMore;
  final String? error;

  _PageState copyWith({
    List<Map<String, Object?>>? messages,
    Object? nextByte = _keep,
    bool? loading,
    bool? loadingMore,
    Object? error = _keep,
  }) => _PageState(
    messages: messages ?? this.messages,
    nextByte: nextByte == _keep ? this.nextByte : (nextByte as int?),
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    error: error == _keep ? this.error : (error as String?),
  );

  static const _keep = Object();
}

/// One subagent's messages, paged forward with from=nextByte. Ported from
/// SubagentPanel.svelte's sheet state machine.
class SubagentTranscriptPage extends ConsumerStatefulWidget {
  const SubagentTranscriptPage({
    super.key,
    required this.gwId,
    required this.rowKey,
    this.rowIndex,
  });

  final String gwId;

  /// The roster row's key at the time the page was opened (`#index` before
  /// omp assigns an id). The row may be RE-KEYED to the id later, so
  /// [rowIndex] backs the lookup up.
  final String rowKey;

  /// The row's stable index, matching rows whose key has migrated.
  final int? rowIndex;

  @override
  ConsumerState<SubagentTranscriptPage> createState() =>
      _SubagentTranscriptPageState();
}

class _SubagentTranscriptPageState
    extends ConsumerState<SubagentTranscriptPage> {
  _PageState _page = const _PageState(
    messages: [],
    nextByte: null,
    loading: false,
    loadingMore: false,
    error: null,
  );

  bool _firstLoadQueued = false;

  /// A row matches by its key OR by its stable index: the roster re-keys
  /// rows when omp assigns the id, and the page must not lose the row.
  bool _matches(SubagentRow r) =>
      r.key == widget.rowKey ||
      (widget.rowIndex != null && r.index == widget.rowIndex);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_firstLoadQueued) return;
    if (ref.read(subagentsStoreProvider.select(_idOf)) != null) {
      // An id is already there: the one and only first load starts now.
      _firstLoadQueued = true;
      _page = _PageState(
        messages: const [],
        nextByte: null,
        loading: true,
        loadingMore: false,
        error: null,
      );
      _load(from: null);
    }
    // No id yet: leave _firstLoadQueued false so the null -> non-null id
    // transition in build's listener starts the first load later.
  }

  String? _idOf(List<SubagentRow> rows) {
    for (final r in rows) {
      if (_matches(r)) return r.id;
    }
    return null;
  }

  SubagentRow? get _row =>
      ref.read(subagentsStoreProvider).where(_matches).firstOrNull;

  /// Page forward. [from] is the previous nextByte; the first request starts
  /// at the beginning (no from param).
  Future<void> _load({required int? from}) async {
    final row = _row;
    final subId = row?.id;
    if (subId == null || subId.isEmpty) return;
    if (_page.messages.isNotEmpty) {
      setState(() => _page = _page.copyWith(loadingMore: true));
    }
    try {
      final env = await ref.read(sessionEnvProvider.future);
      final r = await env.client.subagentMessages(
        widget.gwId,
        subId,
        from: from,
      );
      if (!mounted) return;
      final rawMessages = r['messages'];
      final incoming = <Map<String, Object?>>[
        if (rawMessages is List)
          for (final m in rawMessages)
            if (m is Map) Map<String, Object?>.from(m),
      ];
      final nb = r['nextByte'];
      final next = nb is num ? nb.toInt() : null;
      final reset = r['reset'] == true;
      // A reset rewinds the stream: a nextByte BELOW the current offset is
      // the new cursor, not the end of paging.
      final nextByte = next != null && (reset || from == null || next > from)
          ? next
          : null;
      setState(() {
        _page = _page.copyWith(
          messages: reset ? incoming : [..._page.messages, ...incoming],
          nextByte: nextByte,
          loading: false,
          loadingMore: false,
          error: null,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _page = _page.copyWith(
          loading: false,
          loadingMore: false,
          error: e is GatewayClientError
              ? e.message
              : 'Could not load the transcript',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    // The first load starts as soon as the row has an id: if it arrives
    // AFTER the page opened, the null -> non-null transition kicks it off
    // (guarded by _firstLoadQueued so it loads once).
    ref.listen<SubagentRow?>(
      subagentsStoreProvider.select((rows) => rows.where(_matches).firstOrNull),
      (prev, next) {
        if (!_firstLoadQueued && prev?.id == null && next?.id != null) {
          _firstLoadQueued = true;
          setState(() {
            _page = _PageState(
              messages: const [],
              nextByte: null,
              loading: true,
              loadingMore: false,
              error: null,
            );
          });
          _load(from: null);
        }
      },
    );
    final row = ref.watch(
      subagentsStoreProvider.select((rows) => rows.where(_matches).firstOrNull),
    );
    final title = (row?.agent.isNotEmpty ?? false) ? row!.agent : 'Helper';
    return Scaffold(
      backgroundColor: tokens.canvas,
      appBar: AppBar(
        backgroundColor: tokens.canvas,
        foregroundColor: tokens.ink,
        title: Text(title),
      ),
      body: _body(context, tokens, row),
    );
  }

  Widget _body(BuildContext context, OmpTokens tokens, SubagentRow? row) {
    final page = _page;
    if (page.loading) {
      return Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: tokens.ink3),
        ),
      );
    }
    if (page.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(OmpMetrics.s5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                page.error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.err, fontSize: OmpMetrics.fsSm),
              ),
              const SizedBox(height: OmpMetrics.s3),
              OutlinedButton(
                key: const ValueKey('agents-transcript-retry'),
                onPressed: () {
                  setState(() => _page = _page.copyWith(loading: true));
                  _load(from: null);
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (page.messages.isEmpty) {
      return Center(
        child: Text(
          row?.id != null
              ? 'No messages yet'
              : 'Waiting for the helper to start.',
          style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
        ),
      );
    }
    // Reuse the main transcript reducer + items read-only: the same history
    // appliers, the same block grouping, no new rendering code.
    final transcript = reduce(emptyTranscript(), HistoryInput(page.messages));
    final blocks = toBlocks(transcript.items);
    return ListView.builder(
      padding: const EdgeInsets.all(OmpMetrics.s3),
      itemCount: blocks.length + (page.nextByte != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= blocks.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: OmpMetrics.s2),
            child: Center(
              child: TextButton(
                key: const ValueKey('agents-load-more'),
                onPressed: page.loadingMore
                    ? null
                    : () => _load(from: page.nextByte),
                child: page.loadingMore
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: tokens.ink3,
                        ),
                      )
                    : const Text('Load more'),
              ),
            ),
          );
        }
        final b = blocks[i];
        return switch (b) {
          ToolsBlock() => TranscriptItemView(
            key: ValueKey('agents-block-${b.key}'),
            item: b.tools.first,
            toolRun: b.tools,
          ),
          ItemBlock() => TranscriptItemView(
            key: ValueKey('agents-block-${b.key}'),
            item: b.item,
          ),
        };
      },
    );
  }
}
