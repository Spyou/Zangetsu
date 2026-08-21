import 'package:flutter/material.dart';

import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../models/watch_status.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tracker/tracker.dart';
import '../tracker/tracker_binding_store.dart';
import '../tracker/tracker_hub.dart';
import 'tracker_badge.dart';
import 'tracker_sync_sheet.dart';

/// Tracking entry point on phone: one row per connected tracker, each showing
/// what that tracker matched and its own progress, plus a "Sync all at once"
/// button that opens the original combined editor.
///
/// The combined sheet still exists and still writes to every tracker — this
/// only adds the option of editing one at a time, and of seeing which title
/// each tracker actually matched (a wrong auto-match used to be invisible).
///
/// Returns the episode progress applied by whichever sheet the user used, so
/// the detail screen can grey out watched episodes immediately. Null when
/// nothing was applied.
Future<int?> showTrackerListSheet(
  BuildContext context, {
  required String title,
  required bool isAnime,
  bool reading = false,
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
  String? bindingKey,
}) {
  return showModalBottomSheet<int?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => TrackerListSheet(
      title: title,
      isAnime: isAnime,
      reading: reading,
      malId: malId,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      bindingKey: bindingKey,
    ),
  );
}

class TrackerListSheet extends StatefulWidget {
  const TrackerListSheet({
    super.key,
    required this.title,
    required this.isAnime,
    this.reading = false,
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
    this.bindingKey,
  });

  final String title;
  final bool isAnime;
  final bool reading;
  final int? malId;
  final int? tmdbId;
  final bool tmdbIsTv;
  final String? imdbId;
  final String? bindingKey;

  @override
  State<TrackerListSheet> createState() => _TrackerListSheetState();
}

/// One tracker's row state. [entry] null means nothing matched — the row reads
/// "Add tracking" rather than pretending to know something.
class _Row {
  const _Row({required this.tracker, this.entry, this.pinned = false});

  final Tracker tracker;
  final TrackerEntry? entry;

  /// True when the user picked this match by hand, so the row can distinguish
  /// a confirmed match from a guess.
  final bool pinned;
}

class _TrackerListSheetState extends State<TrackerListSheet> {
  final _hub = sl<TrackerHub>();

  bool _loading = true;
  List<_Row> _rows = const [];
  Map<String, String> _pinnedIds = const {};

  /// The applied progress to hand back, kept across however many per-tracker
  /// edits the user makes before closing.
  int? _applied;

  MediaKind get _kind => widget.reading ? MediaKind.manga : MediaKind.anime;

  ContentMode get _mode =>
      widget.reading ? ContentMode.manga : ContentMode.anime;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = widget.bindingKey;
    _pinnedIds =
        key == null ? const {} : sl<TrackerBindingStore>().get(key);

    final trackers = _hub.connectedForMode(_mode).toList();
    // Each tracker answers for itself; one failing must not blank the others,
    // so every fetch is caught individually.
    final entries = await Future.wait(
      trackers.map((t) async {
        try {
          return await t.fetchEntry(
            malId: widget.malId,
            title: (widget.isAnime || widget.reading) ? widget.title : null,
            tmdbId: widget.tmdbId,
            tmdbIsTv: widget.tmdbIsTv,
            imdbId: widget.imdbId,
            pinnedId: _pinnedIds[t.displayName],
            kind: _kind,
          );
        } catch (_) {
          return null;
        }
      }),
    );
    if (!mounted) return;
    setState(() {
      _rows = [
        for (var i = 0; i < trackers.length; i++)
          _Row(
            tracker: trackers[i],
            entry: entries[i],
            pinned: _pinnedIds.containsKey(trackers[i].displayName),
          ),
      ];
      _loading = false;
    });
  }

  Future<void> _openOne(Tracker t) async {
    final applied = await showTrackerSyncSheet(
      context,
      title: widget.title,
      isAnime: widget.isAnime,
      reading: widget.reading,
      malId: widget.malId,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
      bindingKey: widget.bindingKey,
      tracker: t,
    );
    if (!mounted) return;
    if (applied != null) _applied = applied;
    // Values (and possibly the match) changed — re-read so the row isn't stale.
    setState(() => _loading = true);
    await _load();
  }

  Future<void> _openAll() async {
    final applied = await showTrackerSyncSheet(
      context,
      title: widget.title,
      isAnime: widget.isAnime,
      reading: widget.reading,
      malId: widget.malId,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
      bindingKey: widget.bindingKey,
    );
    if (!mounted) return;
    if (applied != null) _applied = applied;
    Navigator.pop(context, _applied);
  }

  /// "Watching · 5/12 · 8" — whatever this tracker actually knows.
  String _subtitleFor(TrackerEntry e) {
    final bits = <String>[];
    final s = e.status;
    if (s != null) bits.add(shortLabelFor(s, reading: widget.reading));
    final progress = e.progress;
    if (progress != null) {
      final total = widget.reading ? e.chapters : e.maxEpisodes;
      bits.add(total != null && total > 0 ? '$progress/$total' : '$progress');
    }
    final score = e.score;
    if (score != null && score > 0) bits.add(score.toStringAsFixed(0));
    return bits.isEmpty ? 'On your list' : bits.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('Tracking', style: AppText.title),
            const SizedBox(height: 2),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 34),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(
                    'No trackers connected.\nConnect one in Settings → Connections.',
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              )
            else ...[
              for (final r in _rows) _rowTile(r),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _openAll,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Sync all at once'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rowTile(_Row r) {
    final e = r.entry;
    final matched = e?.title;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _openOne(r.tracker),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                TrackerBadge(name: r.tracker.displayName),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            r.tracker.displayName,
                            style: AppText.body.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // Only a pinned match gets a marker — the user chose
                          // it. An automatic match is the norm and doesn't need
                          // decorating.
                          if (e != null && r.pinned) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.push_pin_rounded,
                              size: 13,
                              color: AppColors.textSecondary,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      if (e == null)
                        Text(
                          'Add tracking',
                          style: AppText.body.copyWith(
                            color: AppColors.accent,
                          ),
                        )
                      else ...[
                        if (matched != null)
                          Text(
                            matched,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.body,
                          ),
                        Text(_subtitleFor(e), style: AppText.caption),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
