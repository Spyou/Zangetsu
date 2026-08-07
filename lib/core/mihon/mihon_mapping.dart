import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/page_content.dart';
import '../models/provider_info.dart';

// ── SManga status constants (from SManga.kt companion object) ─────────────────
//   0 = UNKNOWN, 1 = ONGOING, 2 = COMPLETED, 3 = LICENSED,
//   4 = PUBLISHING_FINISHED, 5 = CANCELLED, 6 = ON_HIATUS
//
// Byte-identical constant set to SAnime's — confirmed against SManga.kt and
// the M4a report ("same constants as SAnime.status"). Duplicated rather than
// shared per Decision 3 (see aniyomi_mapping.dart's twin of this function).

MediaStatus _statusFromInt(int? v) {
  switch (v) {
    case 1:
      return MediaStatus.ongoing;
    case 2:
      return MediaStatus.completed;
    case 5:
      return MediaStatus.cancelled;
    case 6:
      return MediaStatus.hiatus;
    default:
      return MediaStatus.unknown;
  }
}

/// Splits the comma-separated `genre` field from SManga into a Dart list.
List<String> _parseGenres(String? genre) {
  if (genre == null || genre.isEmpty) return const [];
  return genre
      .split(',')
      .map((g) => g.trim())
      .where((g) => g.isNotEmpty)
      .toList();
}

/// Folds SManga's `author`/`artist` into [MediaDetail.studios] — see that
/// field's doc comment ("authors → studios"). Both are single names on the
/// Kotlin model (unlike `genre`, neither is documented or split as
/// comma-separated), so each contributes at most one entry. Blank/duplicate
/// values (a work where author and artist are the same person) are dropped.
List<String> _authorsToStudios(String? author, String? artist) {
  final result = <String>[];
  for (final raw in [author, artist]) {
    final v = raw?.trim();
    if (v != null && v.isNotEmpty && !result.contains(v)) {
      result.add(v);
    }
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Public mapping functions
// ─────────────────────────────────────────────────────────────────────────────

/// Converts one SManga JSON object (from getPopular / getLatest / search) into
/// a [MediaItem]. [sourceId] must be the caller's manga source-id string
/// (e.g. `'mihon:<id>'` — the prefix convention is the loader's decision, not
/// this mapping's).
///
/// [headers] are the source's default HTTP headers (Referer/User-Agent).
/// When non-empty they are forwarded as [MediaItem.coverHeaders] so the image
/// widget can supply them when fetching the cover — preventing 403 errors on
/// strict image hosts. Unlike the Aniyomi twin, no synthetic marker key is
/// injected: there is no Mihon-specific cover-image widget to route to (that's
/// UI wiring, out of scope here) — headers are forwarded plain, the same shape
/// `cloudstream_provider.dart` already uses for its own `coverHeaders`.
///
/// Expected JSON keys (from `MihonJson.mangaToJson` — see MihonBridge contract):
///   url           — String  (non-null; opaque source key)
///   title         — String
///   thumbnail_url — String? (cover image)
MediaItem mediaItemFromSManga(
  Map<String, dynamic> j, {
  required String sourceId,
  Map<String, String>? headers,
}) {
  final url = (j['url'] as String?) ?? '';
  final coverHeaders = (headers != null && headers.isNotEmpty)
      ? Map<String, String>.of(headers)
      : null;
  return MediaItem(
    id: url,
    title: (j['title'] as String?) ?? '',
    cover: j['thumbnail_url'] as String?,
    coverHeaders: coverHeaders,
    url: url,
    type: ProviderType.manga,
    sourceId: sourceId,
  );
}

/// Converts one SManga JSON object (from getDetails) + a pre-fetched chapter
/// list into a [MediaDetail]. [sourceId] must be the caller's manga source-id
/// string.
///
/// [headers] behave exactly as in [mediaItemFromSManga].
///
/// Expected JSON keys (from `MihonJson.mangaToJson`):
///   url           — String
///   title         — String
///   thumbnail_url — String?
///   description   — String?
///   genre         — String? (comma-separated, e.g. "Action, Comedy")
///   status        — int    (0=unknown, 1=ongoing, 2=completed, 5=cancelled, 6=hiatus)
///   author        — String? ─┐ folded into MediaDetail.studios — see
///   artist        — String? ─┘ _authorsToStudios above.
MediaDetail mediaDetailFromSManga(
  Map<String, dynamic> j,
  List<Episode> chapters, {
  required String sourceId,
  Map<String, String>? headers,
}) {
  final url = (j['url'] as String?) ?? '';
  final coverHeaders = (headers != null && headers.isNotEmpty)
      ? Map<String, String>.of(headers)
      : null;
  return MediaDetail(
    id: url,
    title: (j['title'] as String?) ?? '',
    cover: j['thumbnail_url'] as String?,
    coverHeaders: coverHeaders,
    url: url,
    description: j['description'] as String?,
    status: _statusFromInt((j['status'] as num?)?.toInt()),
    genres: _parseGenres(j['genre'] as String?),
    studios: _authorsToStudios(j['author'] as String?, j['artist'] as String?),
    episodes: chapters,
    type: ProviderType.manga,
    sourceId: sourceId,
  );
}

/// Converts one SChapter JSON object into an [Episode] (the app's chapter
/// model — see the reading pipeline already shipped on this branch).
///
/// The source `url` (Mihon's opaque chapter key) is stored in [Episode.url]
/// and passed back verbatim to getPages.
///
/// `scanlator` has no *display* field: [Episode] carries no scanlator/group
/// concept (it wasn't added for this task — see the report's self-review) and
/// isn't surfaced anywhere in the returned [Episode], per the constraint
/// against editing shared models. It IS folded into [Episode.id] below,
/// though — a scanlator-less id collides across scanlation groups (MangaDex
/// and friends routinely have several groups release the same chapter
/// number on one source), which would silently merge two distinct chapters'
/// read progress under one id. Disambiguating the id is a `String` I build in
/// this file, not a model change, so it doesn't trip the "no shared model
/// edits" constraint the way adding a field to [Episode] would.
///
/// Expected JSON keys (from `MihonJson.chapterToJson`):
///   url            — String  (opaque chapter key; passed to getPages)
///   name           — String  (chapter title, e.g. "Chapter 1")
///   chapter_number — double  (use -1.0 / negative to signal "unset")
///   date_upload    — int     (Unix millis; 0 = unset)
///   scanlator      — String? (folded into id only — see above; not displayed)
Episode episodeFromSChapter(Map<String, dynamic> j) {
  final url = (j['url'] as String?) ?? '';
  final rawNum = (j['chapter_number'] as num?)?.toDouble();
  // Mihon uses -1.0 as the "no chapter number" sentinel, same as Aniyomi.
  // Plenty of sources never populate it and put the number in the name instead
  // ("Chapter 1: Dream"), so fall back to reading it out of the title — the
  // same thing Mihon's own ChapterRecognition does. Measured on device: with
  // this null, a finished chapter could never scrobble (the tracker guard
  // needs a positive whole number) and chapter ordering fell back to reversing
  // the list.
  final chapterNum = (rawNum != null && rawNum >= 0)
      ? rawNum
      : parseChapterNumber((j['name'] as String?) ?? '');
  final scanlator = (j['scanlator'] as String?)?.trim();

  // Derive a stable id: prefer chapter-number key so reading-history survives
  // URL changes; fall back to the raw URL for specials / unordered chapters.
  final numberedId =
      chapterNum != null ? 'ch-${chapterNum.toStringAsFixed(1)}' : null;
  // Fold the scanlator in when present — otherwise two groups' releases of
  // the same chapter number collide onto one id (see doc comment above). No
  // scanlator → id is byte-identical to the pre-fix 'ch-<n>' form.
  final id = (numberedId != null && scanlator != null && scanlator.isNotEmpty)
      ? '$numberedId-$scanlator'
      : (numberedId ?? url);

  String? dateStr;
  final dateUpload = (j['date_upload'] as num?)?.toInt();
  if (dateUpload != null && dateUpload > 0) {
    dateStr = DateTime.fromMillisecondsSinceEpoch(dateUpload).toIso8601String();
  }

  return Episode(
    id: id.isNotEmpty ? id : url,
    title: (j['name'] as String?) ?? '',
    number: chapterNum,
    url: url,
    date: dateStr,
  );
}

/// Converts one Page JSON element (from `getPages`, as delivered by
/// `MihonBridge.pageDeliveryJson`) into a [PageImage], or `null` when the page
/// never got a resolvable image URL.
///
/// `imageUrl` nullability is the whole contract: the bridge attempts to
/// resolve every page (`ensureImageUrl` + the source's own `imageRequest`)
/// BEFORE replying, so by the time Dart sees this JSON, `imageUrl: null`
/// means resolution genuinely failed for that one page — its siblings in the
/// same chapter are unaffected. See [pagesFromJson], which drops such pages
/// rather than failing the whole chapter.
///
/// Expected JSON keys (`MihonJson.pageToJson` + the bridge's `headers` key):
///   index    — int     (0-based; not needed by [PageImage], ignored here)
///   url      — String  (the page's web URL — NOT the image; ignored here)
///   imageUrl — String? (the direct, fetchable image URL, or null)
///   headers  — Map?    (request headers for `imageUrl`, e.g. Referer)
PageImage? pageImageFromJson(Map<String, dynamic> j) {
  final imageUrl = j['imageUrl'] as String?;
  if (imageUrl == null || imageUrl.isEmpty) return null;

  Map<String, String>? headers;
  final rawHeaders = j['headers'];
  if (rawHeaders is Map && rawHeaders.isNotEmpty) {
    headers = {
      for (final e in rawHeaders.entries) '${e.key}': '${e.value}',
    };
  }

  return PageImage(url: imageUrl, headers: headers);
}

/// Converts the full `getPages` JSON array (already `jsonDecode`d) into an
/// ordered [PageImage] list, silently dropping any element that isn't a page
/// map and any page whose `imageUrl` didn't resolve (see [pageImageFromJson]).
///
/// One bad page never fails the chapter — this mirrors the same tolerant
/// pattern [PageImage.listFromJson] already uses, just keyed off `imageUrl`
/// instead of `url` (a getPages element's `url` is the page's web URL, not
/// the image).
List<PageImage> pagesFromJson(dynamic raw) {
  if (raw is! List) return const [];
  final result = <PageImage>[];
  for (final element in raw) {
    if (element is! Map) continue;
    final page = pageImageFromJson(Map<String, dynamic>.from(element));
    if (page != null) result.add(page);
  }
  return result;
}

/// Best-effort chapter number pulled out of a chapter's display name, for
/// sources that leave `chapter_number` at the -1 sentinel. Mirrors the intent
/// of Mihon's `ChapterRecognition`: find the number that follows a chapter
/// marker, else a lone number in the name. Returns null when nothing sensible
/// is there (title-only specials, "Extra", "Oneshot"), which keeps the
/// existing "unnumbered" behaviour for those.
double? parseChapterNumber(String name) {
  final n = name.toLowerCase();
  // "chapter 12", "chapter 12.5", "ch. 12", "ch 12", "c12"
  final marked = RegExp(r'(?:chapter|chap|ch)\.?\s*(\d+(?:\.\d+)?)').firstMatch(n);
  if (marked != null) {
    final v = double.tryParse(marked.group(1)!);
    if (v != null && v >= 0) return v;
  }
  // "#12"
  final hash = RegExp(r'#\s*(\d+(?:\.\d+)?)').firstMatch(n);
  if (hash != null) {
    final v = double.tryParse(hash.group(1)!);
    if (v != null && v >= 0) return v;
  }
  // A lone number anywhere else ("12 - Dream", "Dream 12"). Deliberately last
  // so a volume/season prefix doesn't win over an explicit chapter marker.
  final bare = RegExp(r'(?<![\d.])(\d+(?:\.\d+)?)(?![\d.])').firstMatch(n);
  if (bare != null) {
    final v = double.tryParse(bare.group(1)!);
    if (v != null && v >= 0) return v;
  }
  return null;
}
