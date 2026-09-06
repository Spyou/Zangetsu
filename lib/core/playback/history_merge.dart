import 'package:hive/hive.dart';

import '../privacy/incognito_mode.dart';
import '../zmode/match_store.dart';
import '../zmode/zmode_ids.dart';
import 'resume_store.dart';
import 'watch_history.dart';

/// Moves Continue Watching rows that were saved under a SOURCE onto the
/// catalogue title they belong to. Runs once.
///
/// History is keyed `sourceId::showUrl` ([WatchHistory]), so the same show
/// watched from Home (`zm` + a `zm://` url) and from a source's own browse
/// screen (that source's id and url) is two rows, at two different episodes,
/// and only the catalogue one ever scrobbles. New watches stopped splitting
/// when the browse screen started resolving titles to the catalogue; this is
/// for the rows already on disk.
///
/// **Only rows carrying a MAL id are touched.** That is an exact identity, so
/// the merge never guesses — and a guess here would move somebody's progress
/// onto a different show and then delete the original. Rows without one (most
/// movies, sources that expose no id) are left exactly as they are and keep
/// working; they simply stay their own record.
class HistoryCanonicalMerge {
  const HistoryCanonicalMerge._();

  /// Lives in the box [WatchHistory] already opens for its sync bookkeeping,
  /// so this needs no box of its own.
  static const String flagKey = 'history_canonical_merge_v1';

  /// Returns how many rows were moved. Never throws: a merge that cannot
  /// finish must not stop the app from starting.
  static Future<int> runOnce({
    required WatchHistory history,
    required ResumeStore resume,
    required MatchStore matches,
  }) async {
    // Incognito refuses history and resume WRITES. Running now would delete
    // the old rows and drop what it was moving, so leave the flag unset and
    // let a later launch do it.
    if (IncognitoMode.on) return 0;
    if (!Hive.isBoxOpen(WatchHistory.syncMetaBox)) return 0;
    final meta = Hive.box(WatchHistory.syncMetaBox);
    if (meta.get(flagKey) == true) return 0;

    var moved = 0;
    try {
      final rows = history.all();
      // What the catalogue side already holds, so a stale source row never
      // overwrites a newer canonical one.
      final canonicalAt = <String, int>{
        for (final r in rows)
          if (r.sourceId == ZmodeIds.sourceId) r.showId: r.updatedAt,
      };

      for (final e in rows) {
        if (e.sourceId == ZmodeIds.sourceId) continue;
        final malId = e.malId;
        final n = e.episodeNumber;
        // A whole episode number is what the canonical url is built from; a
        // half number ("12.5") or none has no position to move to.
        if (malId == null ||
            n == null ||
            n <= 0 ||
            n != n.truncateToDouble()) {
          continue;
        }

        final c = ZCanonical(ZKind.anime, 'mal:$malId');
        final showUrl = ZmodeIds.showUrl(c);
        final ep = n.toInt();
        final newer = canonicalAt[showUrl];
        final stale = newer != null && newer > e.updatedAt;

        if (!stale) {
          // Keep playing from the source this show was actually watched on
          // instead of handing it to the kind's default. The pin is what
          // carries that across.
          if (e.showUrl.isNotEmpty) {
            await matches.pin(
              c,
              SourceMatch(
                sourceId: e.sourceId,
                showUrl: e.showUrl,
                showId: e.showId,
                showTitle: e.showTitle,
                pinned: false,
              ),
            );
          }
          // The in-player resume position lives in its own store, keyed the
          // same way. Without this the merged row would show the right
          // episode and then start it from zero.
          final mark = resume.get(e.sourceId, e.showId, e.episodeId);
          await resume.save(
            ZmodeIds.sourceId,
            showUrl,
            '$ep',
            mark?.position ?? e.position,
            mark?.duration ?? e.duration,
          );
          await history.save(
            HistoryEntry(
              sourceId: ZmodeIds.sourceId,
              showId: showUrl,
              showTitle: e.showTitle,
              cover: e.cover,
              coverHeaders: e.coverHeaders,
              thumbnail: e.thumbnail,
              showUrl: showUrl,
              category: e.category,
              episodeId: '$ep',
              episodeNumber: n,
              episodeUrl: ZmodeIds.episodeUrl(c, ep),
              position: e.position,
              duration: e.duration,
              updatedAt: e.updatedAt,
              malId: malId,
            ),
            flush: true,
          );
          canonicalAt[showUrl] = e.updatedAt;
        }

        // Last, so a failure above leaves the original row untouched rather
        // than losing it.
        await history.remove(e.sourceId, e.showId);
        moved++;
      }
    } catch (_) {
      // Whatever moved, moved. The flag is still set below: retrying a merge
      // that throws halfway would just throw again every launch.
    }
    await meta.put(flagKey, true);
    return moved;
  }
}
