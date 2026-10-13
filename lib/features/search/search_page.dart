// Transcript search page, ported from web SearchView.svelte: debounced query,
// role filter, hits grouped per transcript, live sessions open directly while
// saved ones resume from their file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../state/connection_notifier.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import 'search_hits.dart';

/// Debounce for typing, from the web view's 250 ms.
const searchDebounceMs = 250;

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    super.key,
    required this.onOpenLive,
    required this.onResume,
  });

  final void Function(String gwId) onOpenLive;

  /// Resume a saved transcript. The page never starts a session itself.
  final Future<void> Function(String file, String? cwd) onResume;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;

  /// Bumps on every run: a stale response must never overwrite a newer one.
  int _gen = 0;
  String? _role;
  bool _loading = false;
  String? _error;
  List<SearchHit>? _hits;
  int _total = 0;
  SearchIndexed? _indexed;
  String _lastQuery = '';

  /// Saved transcript with a resume in flight: its rows show a spinner and
  /// ignore taps until it settles.
  String? _resuming;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // The sessions screen stops polling while this page covers it; take one
    // fresh list so 'live' tags (and which hits open vs resume) aren't stale.
    unawaited(ref.read(sessionsStoreProvider.notifier).refresh());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() => _schedule(_controller.text.trim());

  /// Port of the web $effect: empty queries clear everything, unchanged
  /// queries do nothing, everything else re-arms the debounce.
  void _schedule(String query) {
    _debounce?.cancel();
    if (query.isEmpty) {
      _gen++;
      setState(() {
        _loading = false;
        _error = null;
        _hits = null;
        _total = 0;
        _lastQuery = '';
      });
      return;
    }
    if (query == _lastQuery && _hits != null) {
      if (_loading) setState(() => _loading = false);
      return;
    }
    // Loading from the first keystroke (web SearchView): the debounce window
    // shows the spinner or dims the old results instead of a blank body.
    if (!_loading) setState(() => _loading = true);
    _debounce = Timer(
      const Duration(milliseconds: searchDebounceMs),
      () => _run(query),
    );
  }

  /// Role chips are deliberate taps: kill any pending keystroke debounce (it
  /// would fire a duplicate request that aborts this one) and re-run now.
  void _setRole(String? role) {
    if (role == _role) return;
    setState(() => _role = role);
    _debounce?.cancel();
    final query = _controller.text.trim();
    if (query.isNotEmpty) {
      _run(query);
    } else {
      setState(() => _lastQuery = '');
    }
  }

  Future<void> _run(String query) async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final active = ref.read(connectionNotifierProvider).active;
      if (active == null) {
        if (mounted && gen == _gen) {
          setState(() {
            _error = 'Not signed in.';
            _loading = false;
          });
        }
        return;
      }
      // Inside the try: a keystore read can throw too, and must not leave
      // the spinner running with no error.
      final token = await ref.read(tokenStoreProvider).read(active.id);
      if (!mounted || gen != _gen) return;
      final client = ref.read(gatewayClientFactoryProvider)(
        active.url,
        token ?? '',
      );
      final out = await client.search(query, role: _role);
      if (!mounted || gen != _gen) return;
      final parsed = SearchResponse.fromJson(out);
      setState(() {
        _hits = parsed.results;
        _total = parsed.total;
        _indexed = parsed.indexed;
        _lastQuery = query;
        _loading = false;
        _error = null;
      });
    } on GatewayClientError catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = 'Search failed';
        _loading = false;
      });
    }
  }

  /// Live sessions open directly; saved ones resume from their file.
  void _open(SearchHit hit, List<SessionInfo> live) {
    final gwId = liveGwIdFor(hit, live);
    if (gwId != null) {
      widget.onOpenLive(gwId);
      return;
    }
    if (_resuming != null) return;
    setState(() => _resuming = hit.path);
    unawaited(
      widget.onResume(hit.path, hit.cwd).whenComplete(() {
        if (mounted) setState(() => _resuming = null);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final live = ref.watch(sessionsStoreProvider.select((s) => s.live));
    final query = _controller.text.trim();
    final hits = _hits;
    final indexed = _indexed;

    final body = _error != null
        ? _StateText(_error!, color: tokens.err)
        : query.isEmpty
        ? const _StateText('Type to search. Every word is a prefix match.')
        : _loading && (hits == null || hits.isEmpty)
        ? const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : hits != null && hits.isEmpty
        ? _StateText('No matches for "$_lastQuery".')
        : hits == null
        ? const SizedBox.shrink()
        : _Results(
            hits: hits,
            total: _total,
            live: live,
            loading: _loading,
            indexed: indexed,
            resuming: _resuming,
            onOpen: (hit) => _open(hit, live),
          );

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Search transcripts'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OmpMetrics.s4,
                OmpMetrics.s3,
                OmpMetrics.s4,
                0,
              ),
              child: Semantics(
                label: 'Search transcripts',
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search all sessions',
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(OmpMetrics.s4),
              child: Row(
                children: [
                  _roleSegment('All', null, tokens),
                  _roleSegment('You', 'user', tokens),
                  _roleSegment('omp', 'assistant', tokens),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _roleSegment(String label, String? value, OmpTokens tokens) {
    final selected = _role == value;
    return Expanded(
      child: Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        button: true,
        child: InkWell(
          onTap: () => _setRole(value),
          borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
          child: Container(
            constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? tokens.accent : null,
              borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? tokens.accentInk : tokens.ink2,
                  fontSize: OmpMetrics.fsSm,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StateText extends StatelessWidget {
  const _StateText(this.text, {this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Padding(
      padding: const EdgeInsets.all(OmpMetrics.s4),
      child: Text(
        text,
        style: TextStyle(
          color: color ?? tokens.ink3,
          fontSize: OmpMetrics.fsBase,
        ),
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({
    required this.hits,
    required this.total,
    required this.live,
    required this.loading,
    required this.indexed,
    required this.resuming,
    required this.onOpen,
  });

  final List<SearchHit> hits;
  final int total;
  final List<SessionInfo> live;
  final bool loading;
  final SearchIndexed? indexed;

  /// Path of the transcript being resumed, if any.
  final String? resuming;
  final void Function(SearchHit hit) onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    // Flat rows (header then its hits per group) so ListView.builder stays
    // lazy: children are built on demand as they scroll in.
    final rows = <(SearchHitGroup, SearchHit?)>[
      for (final g in groupSearchHits(hits)) ...[
        (g, null),
        for (final h in g.hits) (g, h),
      ],
    ];

    final idx = indexed;
    Widget child = ListView.builder(
      padding: const EdgeInsets.only(bottom: OmpMetrics.s4),
      // One extra row at the end: what the index covers. It sits after the
      // results so it never pushes the list down mid-typing.
      itemCount: rows.length + (idx != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == rows.length) {
          return _StateText(
            'Full text across ${idx!.messages} messages in ${idx.files} '
            'saved sessions. Thinking and tool output are not searched.',
          );
        }
        final (group, hit) = rows[i];
        final busy = resuming == group.path;
        if (hit == null) {
          return _GroupHeader(
            group: group,
            live: live,
            busy: busy,
            onOpen: busy ? null : () => onOpen(group.hits.first),
          );
        }
        return _HitRow(hit: hit, onOpen: busy ? null : () => onOpen(hit));
      },
    );

    if (loading) {
      // A newer query is loading: keep the old results visible, dimmed.
      child = Opacity(opacity: 0.55, child: child);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (total > hits.length)
          _StateText('Top ${hits.length} of $total matches.'),
        Expanded(
          child: Material(color: tokens.bg, child: child),
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.live,
    required this.busy,
    required this.onOpen,
  });

  final SearchHitGroup group;
  final List<SessionInfo> live;
  final bool busy;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final hit = group.hits.first;
    final isLive = searchHitIsLive(hit, live);
    final tag = isLive ? 'live' : (hit.archived ? 'archived' : null);
    // One TalkBack stop per header: label, folder, tag, and what a tap does.
    return Semantics(
      button: true,
      header: true,
      label:
          '${searchHitLabel(hit)}'
          '${tag != null ? ', $tag' : ''}'
          '${(hit.cwd ?? '').isNotEmpty ? ', ${hit.cwd}' : ''}',
      hint: busy ? 'Opening' : (isLive ? 'Open session' : 'Resume session'),
      excludeSemantics: true,
      child: _groupHeaderBody(context, tokens, hit, isLive),
    );
  }

  Widget _groupHeaderBody(
    BuildContext context,
    OmpTokens tokens,
    SearchHit hit,
    bool isLive,
  ) {
    return InkWell(
      onTap: onOpen,
      child: Container(
        constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
        color: tokens.inset,
        padding: const EdgeInsets.symmetric(
          horizontal: OmpMetrics.s3,
          vertical: OmpMetrics.s2,
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      searchHitLabel(hit),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.ink,
                        fontSize: OmpMetrics.fsBase,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ((hit.cwd ?? '').isNotEmpty)
                      Text(
                        hit.cwd!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsXs,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (busy)
              Padding(
                padding: const EdgeInsets.only(left: OmpMetrics.s2),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tokens.accent,
                  ),
                ),
              ),
            // Web parity: 'live' wins; otherwise 'archived' only when the
            // transcript really is in the archive. Ordinary saved sessions
            // carry no tag.
            if (isLive)
              _Tag(
                label: 'live',
                background: tokens.accentSoft,
                color: tokens.accent,
              )
            else if (hit.archived)
              _Tag(
                label: 'archived',
                background: tokens.surface,
                color: tokens.ink3,
              ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.background,
    required this.color,
  });

  final String label;
  final Color background;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: OmpMetrics.s2),
      padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(OmpMetrics.hit),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: OmpMetrics.fsXs),
      ),
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.onOpen});

  final SearchHit hit;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final when = hitWhen(hit.ts);
    final plain = snippetParts(hit.snippet).map((p) => p.text).join();
    // One TalkBack stop per hit (role, snippet, time), like SessionRow.
    return Semantics(
      button: true,
      label:
          '${hit.role == 'user' ? 'You' : 'omp'}: $plain'
          '${when.isNotEmpty ? ', $when' : ''}',
      excludeSemantics: true,
      child: _body(tokens, when),
    );
  }

  Widget _body(OmpTokens tokens, String when) {
    return InkWell(
      onTap: onOpen,
      child: Container(
        constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
        padding: const EdgeInsets.symmetric(
          horizontal: OmpMetrics.s3,
          vertical: OmpMetrics.s2,
        ),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: tokens.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: Text(
                hit.role == 'user' ? 'you' : 'omp',
                style: TextStyle(
                  color: hit.role == 'user' ? tokens.accent : tokens.ink3,
                  fontSize: OmpMetrics.fsXs,
                ),
              ),
            ),
            Expanded(
              child: Semantics(
                button: true,
                child: Text.rich(
                  TextSpan(
                    children: [
                      for (final part in snippetParts(hit.snippet))
                        TextSpan(
                          text: part.text,
                          style: part.marked
                              ? TextStyle(
                                  color: tokens.ink,
                                  fontSize: OmpMetrics.fsBase,
                                  fontWeight: FontWeight.w700,
                                  background: Paint()
                                    ..color = tokens.accentSoft,
                                )
                              : TextStyle(
                                  color: tokens.ink,
                                  fontSize: OmpMetrics.fsBase,
                                ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (when.isNotEmpty) const SizedBox(width: OmpMetrics.s2),
            if (when.isNotEmpty)
              Text(
                when,
                style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsXs),
              ),
          ],
        ),
      ),
    );
  }
}
