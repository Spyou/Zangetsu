import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/ui/app_toast.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';
import 'detail_screen.dart';

/// Open a title that a metadata API pointed at — a relation, a recommendation,
/// or one of a person's works.
///
/// Two ways in, and the kind decides which:
///
///  * Same kind as the page you came from — search THAT source and open the
///    match. A manga's sequel is best read on the source you are already
///    reading it on.
///  * Different kind — a manga's anime adaptation, an author's novel — skip
///    the source entirely and open the metadata page by id. Searching a manga
///    source for an anime could only ever answer "not on this source", which
///    is what it did.
///
/// Falls back to a title search on the current source when there is no id to
/// go on, which is the old behaviour and still right for source-supplied
/// relations.
Future<void> openRelatedTitle(
  BuildContext context, {
  required String title,
  String? romaji,
  String? cover,
  required bool isReading,
  int? malId,
  int? anilistId,
  int? tmdbId,
  bool tmdbIsTv = false,
  required String? sourceId,
  required bool fromReadingPage,
}) async {
  final canonical = _canonicalFor(
    isReading: isReading,
    malId: malId,
    anilistId: anilistId,
    tmdbId: tmdbId,
    tmdbIsTv: tmdbIsTv,
  );
  if (canonical != null && isReading != fromReadingPage) {
    Navigator.of(context).push(
      DetailScreen.route(
        _metaItem(
          canonical,
          title: title,
          cover: cover,
          malId: malId,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
        ),
      ),
    );
    return;
  }

  // No source behind the page (a person opened from a metadata title): there
  // is nothing to search, so the metadata page is the only answer.
  if (sourceId == null || sourceId.isEmpty) {
    if (canonical == null) {
      showAppToast(context, context.l10n.couldntOpenTitle(title));
      return;
    }
    Navigator.of(context).push(
      DetailScreen.route(
        _metaItem(
          canonical,
          title: title,
          cover: cover,
          malId: malId,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
        ),
      ),
    );
    return;
  }

  try {
    final results = await sl<CatalogueRepository>().search(
      title,
      sourceId: sourceId,
    );
    if (!context.mounted) return;
    final match = bestTitleMatch(
      results,
      title,
      altTitle: romaji,
      wantedMalId: isReading ? null : malId,
    );
    if (match != null) {
      Navigator.of(context).push(DetailScreen.route(match));
      return;
    }
    // Nothing on this source. Open the metadata page rather than refusing.
    //
    // Staying put was the older behaviour, on the reasoning that you asked for
    // this title ON this source. In practice a relation is usually the first
    // time you have heard of the title, a single source rarely carries a whole
    // franchise, and a toast is a dead end — the metadata page at least lets
    // you pick a source that does have it. The toast survives only for
    // relations with no id, where there is no metadata page to open.
    if (canonical != null) {
      Navigator.of(context).push(
        DetailScreen.route(
          _metaItem(
            canonical,
            title: title,
            cover: cover,
            malId: malId,
            tmdbId: tmdbId,
            tmdbIsTv: tmdbIsTv,
          ),
        ),
      );
      return;
    }
    showAppToast(context, context.l10n.titleIsntOnThisSource(title));
  } catch (_) {
    if (context.mounted) {
      showAppToast(context, context.l10n.couldntOpenTitle(title));
    }
  }
}

/// Exposed for tests: which catalogue entry a relation points at is the rule
/// the whole routing turns on, and it is pure.
@visibleForTesting
ZCanonical? canonicalForRelated({
  required bool isReading,
  int? malId,
  int? anilistId,
  int? tmdbId,
  bool tmdbIsTv = false,
}) => _canonicalFor(
  isReading: isReading,
  malId: malId,
  anilistId: anilistId,
  tmdbId: tmdbId,
  tmdbIsTv: tmdbIsTv,
);

ZCanonical? _canonicalFor({
  required bool isReading,
  int? malId,
  int? anilistId,
  int? tmdbId,
  bool tmdbIsTv = false,
}) {
  if (malId != null) {
    // MAL's manga and anime ids are separate sequences, so the flag is what
    // makes the number mean anything. Novels live under manga on AniList and
    // are indistinguishable here, so they open as manga — the reader handles
    // both.
    return ZCanonical(isReading ? ZKind.manga : ZKind.anime, 'mal:$malId');
  }
  if (tmdbId != null) {
    return ZCanonical(tmdbIsTv ? ZKind.tv : ZKind.movie, 'tmdb:$tmdbId');
  }
  // AniList's own id, for the entries with no MAL id. The catalogue resolves
  // `al:` already — it keys its own rows that way when idMal is null — so this
  // is the same identity, not a new one. Without it a relation on a Korean or
  // Chinese title had nothing to open and could only search the source.
  if (anilistId != null) {
    return ZCanonical(isReading ? ZKind.manga : ZKind.anime, 'al:$anilistId');
  }
  return null;
}

/// The `zm://` stand-in for a title we only know from a metadata API.
MediaItem _metaItem(
  ZCanonical c, {
  required String title,
  String? cover,
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
}) => MediaItem(
  id: c.id,
  title: title,
  cover: cover,
  url: ZmodeIds.showUrl(c),
  type: switch (c.kind) {
    ZKind.manga => ProviderType.manga,
    ZKind.novel => ProviderType.novel,
    // ProviderType has no `tv`: series and films are both `movie` there, and
    // tmdbIsTv carries the distinction.
    ZKind.movie || ZKind.tv => ProviderType.movie,
    ZKind.anime => ProviderType.anime,
  },
  sourceId: ZmodeIds.sourceId,
  malId: malId,
  tmdbId: tmdbId,
  tmdbIsTv: tmdbIsTv,
);
