import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/playback/search_source_prefs.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

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

  bool get isCloudStream => id.startsWith('cs:');
}

class _SourceHealthScreenState extends State<SourceHealthScreen> {
  SourceRepository get _repo => sl<SourceRepository>();
  SourceHealthStore get _health => sl<SourceHealthStore>();
  SearchSourcePrefs get _searchPrefs => sl<SearchSourcePrefs>();

  /// A generic query that broadly matches across anime / movies / series so a
  /// healthy source returns SOMETHING — but a 0-result response still counts as
  /// alive (only error/timeout marks a source dead).
  static const String _probeQuery = 'one';

  /// Hard per-source cap so a hung source resolves as dead instead of leaving
  /// the row spinning forever. Comfortably above the native search timeout.
  static const Duration _probeTimeout = Duration(seconds: 12);

  List<_ProbeResult> _results = const [];
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runTests());
  }

  /// Probes every enabled source concurrently, updating each row + the store as
  /// results land.
  Future<void> _runTests() async {
    if (_testing) return;
    final sources = _repo.loadedSources;
    setState(() {
      _testing = true;
      _results = [for (final s in sources) _ProbeResult(id: s.id, name: s.name)];
    });

    await Future.wait(_results.map(_probe));

    if (mounted) setState(() => _testing = false);
  }

  Future<void> _probe(_ProbeResult r) async {
    final sw = Stopwatch()..start();
    SourceOutcome outcome;
    int count = 0;
    try {
      final res = await _repo
          .searchStatus(_probeQuery, sourceId: r.id)
          .timeout(
            _probeTimeout,
            onTimeout: () =>
                (items: const <MediaItem>[], outcome: SourceOutcome.timeout),
          );
      count = res.items.length;
      outcome = res.outcome;
    } catch (_) {
      outcome = SourceOutcome.error;
    }
    sw.stop();
    // ignore: unawaited_futures
    _health.record(r.id, outcome, responseMs: sw.elapsedMilliseconds);
    if (!mounted) return;
    setState(() {
      r.running = false;
      r.outcome = outcome;
      r.responseMs = sw.elapsedMilliseconds;
      r.resultCount = count;
    });
  }

  // ── status presentation ────────────────────────────────────────────────────
  static const Color _green = Color(0xFF35C759);

  ({Color color, IconData icon, String label}) _present(SourceOutcome o) {
    // Only a hard error (a thrown failure / unreachable host) is "Dead". A slow
    // response, a long search that times out (e.g. Stremio's addon aggregation),
    // a Cloudflare challenge, or an empty result all mean the source is ALIVE —
    // show Working, not a misleading red Dead.
    if (o == SourceOutcome.error) {
      return (
        color: AppColors.accent,
        icon: Icons.cancel_rounded,
        label: 'Dead',
      );
    }
    return (color: _green, icon: Icons.check_circle_rounded, label: 'Working');
  }

  @override
  Widget build(BuildContext context) {
    final working = _results
        .where((r) =>
            !r.running &&
            r.outcome != null &&
            r.outcome != SourceOutcome.error)
        .length;
    final done = _results.where((r) => !r.running).length;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Source health', style: AppText.title),
        actions: [
          IconButton(
            tooltip: 'Re-test',
            icon: const Icon(Icons.refresh_rounded),
            color: AppColors.textPrimary,
            onPressed: _testing ? null : _runTests,
          ),
        ],
      ),
      body: _results.isEmpty
          ? Center(
              child: Text(
                'No enabled sources to test.',
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
                          ? 'Testing ${_results.length} source'
                              '${_results.length == 1 ? '' : 's'}…'
                          : '$working of $done working. Slow or empty sources are '
                              'still alive — only a source that errors out is '
                              'marked dead.',
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
    // No timing — response speed was misleading ("Slow" sources are fine). Just
    // surface the result count when the source returned hits.
    final c = result.resultCount;
    if (c != null && c > 0) return '$c result${c == 1 ? '' : 's'}';
    return null;
  }

  bool get _isDead => result.outcome == SourceOutcome.error;

  @override
  Widget build(BuildContext context) {
    final o = result.outcome;
    final p = o == null ? null : present(o);
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
                      Text('Testing…', style: AppText.caption)
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
                    'Not searched',
                    style: AppText.overline.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (result.running)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent,
              ),
            )
          else if (_isDead && onDisable != null && searchIncluded)
            TextButton(
              onPressed: onDisable,
              style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              child: const Text('Remove'),
            ),
        ],
      ),
    );
  }
}
