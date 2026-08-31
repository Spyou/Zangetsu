import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/ui/settings_widgets.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/search_source_prefs.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/repository/source_repository.dart';
import '../search/bloc/search_bloc.dart' show SearchBloc;
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../l10n/l10n.dart';

/// "Test sources" — probes every enabled source concurrently and shows, per
/// source, whether it's Working / Slow / Dead (with the reason). A probe asks
/// "does it RESPOND without error/timeout" (even 0 results = alive), NOT "does
/// it have this exact title". Results update [SourceHealthStore] so the live
/// search ordering benefits from a manual test too.
///
/// The CF "verifying" overlay never pops during probes: JS search routes through
/// the provider-manager `search` path (solver suppressed) and CloudStream search
/// goes through native `searchStatus` (bumps `CfClearance.searchDepth`).
class SourceHealthScreen extends StatefulWidget {
  const SourceHealthScreen({super.key});

  @override
  State<SourceHealthScreen> createState() => _SourceHealthScreenState();
}

/// One probe's live result. [running] while in flight; otherwise the resolved
/// outcome + measured response time.
class _ProbeResult {
  _ProbeResult({required this.id, required this.name});

  final String id;
  final String name;
  bool running = true;
  SourceOutcome? outcome;
  int? responseMs;
  int? resultCount;

  /// The first few search hits, kept so the deep check has something to open.
  ///
  /// More than one on purpose: a single title can legitimately have no chapters
  /// or episodes (a stub entry, or everything filtered out by language), and
  /// judging a whole source on that one pick is how a healthy source gets called
  /// broken.
  List<String> topUrls = const [];

  /// Deep check: did opening a title and listing its episodes/chapters work?
  /// Null when the deep check hasn't run (or couldn't).
  bool? deepOk;

  /// Why the deep check failed, in the user's words.
  String? deepNote;

  bool get isCloudStream => id.startsWith('cs:');
}

class _SourceHealthScreenState extends State<SourceHealthScreen> {
  SourceRepository get _repo => sl<SourceRepository>();
  SourceHealthStore get _health => sl<SourceHealthStore>();
  SearchSourcePrefs get _searchPrefs => sl<SearchSourcePrefs>();

  /// Several broad queries, tried in order until one returns hits.
  ///
  /// One fixed word was a false-negative machine: a source with nothing
  /// matching it answered with 0 results and got reported as fine. CloudStream's
  /// own provider tester does the same thing for the same reason — it tries a
  /// list and only calls search broken when EVERY query comes back empty.
  static const List<String> _probeQueries = ['one', 'the', 'love'];

  /// Deliberately shorter than [SearchBloc.sourceTimeout].
  ///
  /// Search caps ONE source the user is actively waiting on, so it can afford
  /// 60s. This screen probes every installed source, so a long cap just pins a
  /// worker slot on a host that isn't answering and starves the rest of the
  /// list. A source slower than this reads context.l10n.timedOut here and may still work
  /// in search — that's the honest trade, and it's why the label says timed out
  /// rather than dead.
  static const Duration _probeTimeout = Duration(seconds: 20);

  /// How many sources are probed at once.
  ///
  /// Every source used to be fired simultaneously — 70 concurrent probes, each
  /// now up to three requests, every one calling setState and rebuilding the
  /// whole list. Two runs overlapping made it ~140 and the UI stopped
  /// responding. A small pool keeps the work bounded no matter how many
  /// sources are installed.
  static const int _maxConcurrent = 6;

  /// Deep checks run far fewer at a time.
  ///
  /// A deep check calls `episodes()`, and for JS sources that executes the
  /// QuickJS runtime ON THE UI ISOLATE (the known open item in the perf notes).
  /// Six of those in flight left no room for the UI to draw and the screen
  /// stopped responding. Two keeps it usable; the real fix is moving that work
  /// off the UI isolate, which is a much bigger change than this screen.
  static const int _maxConcurrentDeep = 2;

  List<_ProbeResult> _results = const [];
  bool _testing = false;

  /// Whether the last run also opened a title from each source. Off by default:
  /// it's several extra requests per source, so it's an explicit choice.
  bool _deep = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runTests());
  }

  /// Probes every enabled source concurrently, updating each row + the store as
  /// results land.
  /// Bumped per run. A superseded run stops touching state (and stops taking
  /// new work) instead of racing the one that replaced it.
  int _runGen = 0;

  Future<void> _runTests({bool deep = false}) async {
    final gen = ++_runGen;
    final sources = _repo.loadedSources;
    setState(() {
      _testing = true;
      _deep = deep;
      _results = [for (final s in sources) _ProbeResult(id: s.id, name: s.name)];
    });

    // Fixed-size worker pool over a shared cursor, so at most
    // [_maxConcurrent] probes are ever in flight.
    final queue = List<_ProbeResult>.of(_results);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (gen != _runGen || !mounted) return;
        final i = next++;
        if (i >= queue.length) return;
        await _probe(queue[i], deep: deep, gen: gen);
        // Hand the frame back between sources — without this a run of
        // synchronous provider work never lets the list repaint.
        await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait([
      for (var i = 0; i < (deep ? _maxConcurrentDeep : _maxConcurrent); i++)
        worker(),
    ]);

    if (mounted && gen == _runGen) setState(() => _testing = false);
  }

  Future<void> _probe(
    _ProbeResult r, {
    required int gen,
    bool deep = false,
  }) async {
    final sw = Stopwatch()..start();
    SourceOutcome outcome = SourceOutcome.empty;
    int count = 0;
    var topUrls = const <String>[];

    // Try each query until one returns hits. A later success overrides an
    // earlier empty/failure — the source clearly works, the first word just
    // didn't match.
    for (final q in _probeQueries) {
      if (gen != _runGen) return; // superseded mid-probe; stop making requests
      try {
        final res = await _repo
            .searchStatus(q, sourceId: r.id)
            .timeout(
              _probeTimeout,
              onTimeout: () =>
                  (items: const <MediaItem>[], outcome: SourceOutcome.timeout),
            );
        outcome = res.outcome;
        if (res.items.isNotEmpty) {
          count = res.items.length;
          topUrls = [for (final i in res.items.take(3)) i.url];
          break;
        }
      } catch (_) {
        outcome = SourceOutcome.error;
      }
      // A hard failure is about the source, not the word — no point retrying.
      if (outcome == SourceOutcome.error ||
          outcome == SourceOutcome.blocked ||
          outcome == SourceOutcome.timeout) {
        break;
      }
    }
    sw.stop();
    if (gen != _runGen) return; // a newer run replaced this one
    // Records exactly what it always did, so search's ordering and skipping are
    // unchanged by anything on this screen.
    // ignore: unawaited_futures
    _health.record(r.id, outcome, responseMs: sw.elapsedMilliseconds);
    if (!mounted) return;
    setState(() {
      // Still spinning only when a deep check is about to run for this row;
      // otherwise the probe IS the result.
      r.running = deep && topUrls.isNotEmpty;
      r.outcome = outcome;
      r.responseMs = sw.elapsedMilliseconds;
      r.resultCount = count;
      r.topUrls = topUrls;
    });
    if (deep && topUrls.isNotEmpty) await _deepCheck(r, topUrls, gen);
  }

  /// Opens the first search hit and lists its episodes/chapters.
  ///
  /// This is the part a search-only probe can't answer: a source can search
  /// perfectly and still be unable to open anything, which is the difference
  /// between "responds" and "usable". CloudStream's tester goes further still
  /// and resolves video links; this stops at the episode list, which is the
  /// same check for every mode (anime episodes, manga and novel chapters all
  /// come back through `episodes`).
  Future<void> _deepCheck(_ProbeResult r, List<String> urls, int gen) async {
    bool ok = false;
    String? note;
    var opened = false;
    for (final url in urls) {
      if (gen != _runGen) return;
      try {
        final eps = await _repo
            .episodes(url, sourceId: r.id)
            .timeout(_probeTimeout, onTimeout: () => const []);
        opened = true;
        if (eps.isNotEmpty) {
          ok = true;
          note = '${eps.length} to play';
          break;
        }
      } catch (_) {
        // Try the next title before blaming the source.
      }
    }
    if (!ok) {
      note = opened
          ? 'opens, but lists nothing to play'
          : "can't open titles";
    }
    if (!mounted || gen != _runGen) return;
    setState(() {
      r.running = false;
      r.deepOk = ok;
      r.deepNote = note;
    });
  }

  // ── status presentation ────────────────────────────────────────────────────
  static const Color _green = Color(0xFF35C759);

  static const Color _amber = Color(0xFFE0A33A);

  /// The outcome as it actually was.
  ///
  /// This used to collapse to Working/Dead, which meant a Cloudflare-blocked
  /// source, a source that timed out, and a source returning nothing all wore a
  /// green tick — while the search screen, looking at the same store, called
  /// those same sources blocked or unreachable. Two screens, opposite answers.
  ///
  /// Green now means "you'll get results". Amber means "it answered, but you may
  /// get nothing out of it". Red means broken. Only red is [SourceHealth.dead]
  /// in the store, so search's skipping is untouched by this.
  ({Color color, IconData icon, String label}) _present(SourceOutcome o) =>
      switch (o) {
        SourceOutcome.ok => (
          color: _green,
          icon: Icons.check_circle_rounded,
          label: context.l10n.working,
        ),
        SourceOutcome.slow => (
          color: _amber,
          icon: Icons.hourglass_bottom_rounded,
          label: context.l10n.slow,
        ),
        SourceOutcome.empty => (
          color: _amber,
          icon: Icons.search_off_rounded,
          label: context.l10n.noResults,
        ),
        SourceOutcome.timeout => (
          color: _amber,
          icon: Icons.hourglass_empty_rounded,
          label: context.l10n.timedOut,
        ),
        SourceOutcome.blocked => (
          color: _amber,
          icon: Icons.shield_outlined,
          label: context.l10n.blocked,
        ),
        SourceOutcome.error => (
          color: AppColors.accent,
          icon: Icons.cancel_rounded,
          label: context.l10n.dead,
        ),
      };

  @override
  Widget build(BuildContext context) {
    // context.l10n.working means it returned results — not merely that it answered.
    final working = _results
        .where((r) => !r.running && r.outcome == SourceOutcome.ok)
        .length;
    final done = _results.where((r) => !r.running).length;
    final unusable = _results
        .where((r) => !r.running && r.deepOk == false)
        .length;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        context.l10n.sourceHealth,
        actions: [
          IconButton(
            tooltip: 'Deep test (opens a title from each source)',
            icon: const Icon(Icons.biotech_outlined),
            color: _deep ? AppColors.accent : AppColors.textPrimary,
            // Live even mid-run. The screen kicks off a test on open, and
            // disabling this until that finished meant waiting out the whole
            // list before you could ask for the deeper one. Safe now that a new
            // run supersedes the old via [_runGen] instead of racing it.
            onPressed: () => _runTests(deep: true),
          ),
          IconButton(
            tooltip: context.l10n.reTest,
            icon: const Icon(Icons.refresh_rounded),
            color: AppColors.textPrimary,
            onPressed: _testing ? null : () => _runTests(),
          ),
        ],
      ),
      body: _results.isEmpty
          ? Center(
              child: Text(
                context.l10n.noEnabledSourcesToTest,
                style: AppText.body,
              ),
            )
          : RefreshIndicator(
              color: AppColors.accent,
              backgroundColor: AppColors.surface,
              onRefresh: _runTests,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                    child: Text(
                      _testing
                          ? '${_deep ? 'Deep t' : 'T'}esting '
                              '${_results.length} source'
                              '${_results.length == 1 ? '' : 's'}…'
                          : '$working of $done returned results.'
                              '${unusable > 0 ? ' $unusable opened nothing '
                                  'playable.' : ''}'
                              ' Amber answered but may give you nothing;'
                              ' only red is treated as dead.',
                      style: AppText.caption,
                    ),
                  ),
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < _results.length; i++) ...[
                          if (i > 0)
                            const Divider(
                              height: 0.5,
                              thickness: 0.5,
                              color: AppColors.hairline,
                            ),
                          _HealthRow(
                            result: _results[i],
                            present: _present,
                            onDisable: _results[i].isCloudStream
                                ? null
                                : () => _disableForSearch(_results[i]),
                            searchIncluded:
                                _searchPrefs.isIncluded(_results[i].id),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Inline action for a dead source: drop it from cross-source search (the same
  /// search-only toggle the source picker uses). Reversible from search settings.
  Future<void> _disableForSearch(_ProbeResult r) async {
    await _searchPrefs.setIncluded(r.id, false);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text('${r.name} removed from search')),
      );
  }
}

/// One source row: name + status pill (Working / Slow / Dead-reason) with the
/// response time / result count, plus an inline "remove from search" action for
/// a dead JS source.
class _HealthRow extends StatelessWidget {
  const _HealthRow({
    required this.result,
    required this.present,
    required this.searchIncluded,
    this.onDisable,
  });

  final _ProbeResult result;
  final ({Color color, IconData icon, String label}) Function(SourceOutcome)
      present;
  final bool searchIncluded;
  final VoidCallback? onDisable;

  String? get _meta {
    if (result.running) return null;
    // The deep check answers the question the search probe can't ("can I
    // actually open anything?"), so when it ran it's the more useful line.
    final note = result.deepNote;
    if (note != null) return note;
    // No timing — response speed was misleading (context.l10n.slow sources are fine). Just
    // surface the result count when the source returned hits.
    final c = result.resultCount;
    if (c != null && c > 0) return '$c result${c == 1 ? '' : 's'}';
    return null;
  }

  bool get _isDead => result.outcome == SourceOutcome.error;

  @override
  Widget build(BuildContext context) {
    final o = result.outcome;
    var p = o == null ? null : present(o);
    // Searching fine but opening nothing is exactly the case a search-only
    // probe called context.l10n.working. Don't let the green tick stand.
    if (p != null && result.deepOk == false) {
      p = (
        color: const Color(0xFFE0A33A),
        icon: Icons.error_outline_rounded,
        label: context.l10n.notUsable,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.name,
                  style: AppText.headline.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (result.running)
                      Text(context.l10n.testing, style: AppText.caption)
                    else if (p != null) ...[
                      Icon(p.icon, size: 14, color: p.color),
                      const SizedBox(width: 5),
                      Text(
                        p.label,
                        style: AppText.caption.copyWith(
                          color: p.color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_meta != null) ...[
                        Text('  ·  ', style: AppText.caption),
                        Flexible(
                          child: Text(
                            _meta!,
                            style: AppText.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
                if (!result.running && !searchIncluded) ...[
                  const SizedBox(height: 3),
                  Text(
                    context.l10n.notSearched,
                    style: AppText.overline.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (result.running)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent,
              ),
            )
          else if (_isDead && onDisable != null && searchIncluded)
            (sl.isRegistered<AppMode>() && sl<AppMode>().isTv)
                ? TvListFocusable(
                    semanticLabel: 'Remove ${result.name}',
                    onTap: onDisable!,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Text(
                        context.l10n.removeDownloadTooltip,
                        style: AppText.body.copyWith(color: AppColors.accent),
                      ),
                    ),
                  )
                : TextButton(
                    onPressed: onDisable,
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.accent),
                    child: Text(context.l10n.navTabsRemove),
                  ),
        ],
      ),
    );
  }
}
