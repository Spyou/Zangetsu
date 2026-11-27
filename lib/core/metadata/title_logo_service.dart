import 'dart:async';

import 'package:dio/dio.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../stremio/stremio_ref.dart';
import '../zmode/zmode_ids.dart';
import 'tmdb.dart';

/// Best-effort TMDB "title logo" (the stylized title-art PNG) and backdrop
/// ("banner") for a hero item — the logo lets the banner show stylized title
/// art instead of plain text, and the banner lets an AniList-sourced anime
/// (whose own `bannerImage` is often missing or low-res) show TMDB's backdrop
/// instead. Resolves by tmdbId when the item has one, else a title search —
/// both come off the one `/images` response, so asking for both costs one
/// network round trip, not two.
///
/// Two-level cache so neither "pops in" every time:
///  - in-memory (per session),
///  - Hive ([_boxName] / [_bannerBoxName], persisted) — keyed by tmdbId/title,
///    value = image URL ('' means "genuinely has none", so we don't re-search
///    it).
/// Only RESOLVED results are cached; a network error (e.g. a TMDB reset) is NOT
/// cached, so a later attempt can still succeed once TMDB is reachable. Any
/// failure yields null → the banner keeps its text title / original art.
class TitleLogoService {
  TitleLogoService(this._dio, {this.addonLogoFor});
  final Dio _dio;
  final Future<String?> Function(MediaItem)? addonLogoFor;

  static const String _boxName = 'logo_cache';
  // Bumped each time what gets cached here changes shape (v2: w780→original;
  // v3: prefer poster over backdrop; v4: plain backdrop first again) —
  // otherwise an already-cached (now stale) banner would be served forever
  // instead of being re-resolved.
  static const String _bannerBoxName = 'tmdb_banner_cache_v4';

  final Map<String, String> _mem = {}; // '' = known "no logo"
  final Map<String, String> _bannerMem = {}; // '' = known "no backdrop"
  final Set<String> _failedAddonLogos = {};
  final Map<String, Future<String?>> _stremioLookups = {};
  final Map<String, Future<_TmdbImages>> _tmdbLookups = {};
  Future<void> _posterLogoQueue = Future<void>.value();
  Box<String>? _boxRef;
  Box<String> get _box => _boxRef ??= Hive.box<String>(_boxName);
  Box<String>? _bannerBoxRef;
  Box<String> get _bannerBox =>
      _bannerBoxRef ??= Hive.box<String>(_bannerBoxName);

  /// Open the persisted caches. Call once in initDependencies before use.
  ///
  /// Resilient: a half-written frame (e.g. the app was killed mid-cache) can make
  /// a box fail — or hang — to open, which would trap the whole app on the
  /// splash. Both caches are disposable, so on any failure/timeout we wipe the
  /// offending one from disk and reopen fresh instead of blocking boot.
  static Future<void> init() async {
    for (final box in [_boxName, _bannerBoxName]) {
      try {
        await openBoxSafely<String>(box).timeout(const Duration(seconds: 6));
      } catch (_) {
        try {
          await Hive.deleteBoxFromDisk(box);
        } catch (_) {}
        try {
          await openBoxSafely<String>(box);
        } catch (_) {}
      }
    }
  }

  /// Warm logos for the hero carousel up front — SEQUENTIALLY (one TMDB lookup
  /// chain at a time), so it never bursts requests at TMDB (which would trip its
  /// connection-reset rate limit) nor competes for the network all at once. By
  /// the time a banner rotates in, its logo is already cached → no pop-in.
  Future<void> prefetch(List<MediaItem> items) async {
    for (final it in items) {
      if (it.sourceId == stremioSourceId && _imageUrl(it.titleLogo) == null) {
        continue;
      }
      try {
        await logoFor(it);
      } catch (_) {
        /* best-effort */
      }
    }
  }

  /// Reuse title artwork during playback startup without a metadata request.
  String? cachedLogoFor(MediaItem item) {
    String? read(String key) =>
        _mem[key] ?? (Hive.isBoxOpen(_boxName) ? _box.get(key) : null);

    if (item.sourceId == stremioSourceId) {
      var id = item.id;
      if (StremioRef.isRef(item.url)) {
        try {
          final ref = StremioRef.parse(item.url);
          id = stremioMediaId(
            type: ref.type,
            itemId: ref.itemId,
            installationId: ref.installationId,
          );
        } on FormatException {
          // Retain the item's existing identity if its reference is malformed.
        }
      }
      final logo =
          _imageUrl(item.titleLogo) ??
          _imageUrl(read('stremio-title:$id')) ??
          _imageUrl(read('stremio-title:${item.id}'));
      if (logo != null && !_failedAddonLogos.contains(logo)) return logo;
    }
    if (item.tmdbId == null) {
      final show = ZmodeIds.parseShow(item.url);
      if (show != null && show.id.startsWith('tmdb:')) {
        final id = int.tryParse(show.id.substring(5));
        if (id != null) {
          return _imageUrl(read('id:$id:${show.kind == ZKind.tv}'));
        }
      }
    }
    return _imageUrl(read(_key(item)));
  }

  Future<String?> logoFor(MediaItem item) async {
    if (item.sourceId != stremioSourceId) return _tmdbLogoFor(item);
    final key = '${item.id}|${item.titleLogo ?? ''}';
    return _stremioLookups.putIfAbsent(
      key,
      () => _stremioLogoFor(item).whenComplete(() {
        _stremioLookups.remove(key);
      }),
    );
  }

  Future<String?> _stremioLogoFor(MediaItem item) async {
    final addonKey = 'stremio-title:${item.id}';
    final cached =
        _mem[addonKey] ??
        (Hive.isBoxOpen(_boxName) ? _box.get(addonKey) : null);
    var addonLogo = _imageUrl(item.titleLogo) ?? cached;
    if (addonLogo == null && addonLogoFor != null) {
      try {
        addonLogo = _imageUrl(
          await addonLogoFor!(item).timeout(const Duration(seconds: 5)),
        );
      } catch (_) {
        // Missing addon metadata still permits the existing TMDB fallback.
      }
    }
    if (addonLogo != null && !_failedAddonLogos.contains(addonLogo)) {
      _mem[addonKey] = addonLogo;
      if (cached != addonLogo && Hive.isBoxOpen(_boxName)) {
        try {
          await _box.put(addonKey, addonLogo);
        } catch (_) {
          // A disposable cache must not hide an available logo.
        }
      }
      return addonLogo;
    }
    return _tmdbLogoFor(item);
  }

  /// Only a failed addon image may trigger the TMDB fallback.
  Future<String?> fallbackFor(MediaItem item, String failedUrl) async {
    if (item.sourceId != stremioSourceId) return null;
    final key = 'stremio-title:${item.id}';
    final addonLogo =
        _imageUrl(item.titleLogo) ??
        _mem[key] ??
        (Hive.isBoxOpen(_boxName) ? _box.get(key) : null);
    if (addonLogo != failedUrl) return null;
    _failedAddonLogos.add(failedUrl);
    final fallback = await logoFor(item);
    return fallback == failedUrl ? null : fallback;
  }

  static String? _imageUrl(String? value) {
    final text = value?.trim();
    final uri = text == null ? null : Uri.tryParse(text);
    return uri != null &&
            uri.host.isNotEmpty &&
            (uri.scheme == 'https' || uri.scheme == 'http')
        ? text
        : null;
  }

  static String _key(MediaItem item) => item.tmdbId != null
      ? 'id:${item.tmdbId}:${item.tmdbIsTv}'
      : 'q:${(item.englishTitle ?? item.title).toLowerCase()}';

  Future<String?> _tmdbLogoFor(MediaItem item) async {
    final key = _key(item);
    final cached = _mem[key] ?? _box.get(key);
    if (cached != null) {
      _mem[key] = cached;
      return cached.isEmpty ? null : cached;
    }
    try {
      final url = (await _images(item, key)).logo;
      // Cache the resolved result (a URL, or '' for a genuine "no logo").
      _mem[key] = url ?? '';
      if (url != null) await _box.put(key, url);
      return url;
    } catch (_) {
      // Network error (e.g. a TMDB reset) — do NOT cache, so a later attempt
      // (this session or a future launch) can still resolve the logo.
      return null;
    }
  }

  /// TMDB backdrop ("banner") for an item whose own art is missing or weak —
  /// an AniList anime's `bannerImage`, mainly. Same id resolution and cache
  /// shape as [logoFor], in a separate box so a title with a logo but no
  /// backdrop (or vice versa) caches each independently.
  Future<String?> bannerFor(MediaItem item) async {
    final key = _key(item);
    final cached = _bannerMem[key] ?? _bannerBox.get(key);
    if (cached != null) {
      _bannerMem[key] = cached;
      return cached.isEmpty ? null : cached;
    }
    try {
      final url = (await _images(item, key)).banner;
      _bannerMem[key] = url ?? '';
      if (url != null) await _bannerBox.put(key, url);
      return url;
    } catch (_) {
      return null;
    }
  }

  /// Poster grids can build many cards at once. Keep their opt-in logo
  /// lookups sequential so a large grid doesn't burst TMDB requests.
  Future<String?> logoForPoster(MediaItem item) async {
    final previous = _posterLogoQueue;
    final done = Completer<void>();
    _posterLogoQueue = done.future;
    await previous;
    try {
      return await logoFor(item);
    } finally {
      done.complete();
    }
  }

  /// Fetches TMDB's `/images` for [item] (search-by-title when it has no
  /// tmdbId) and pulls both the logo and the lead backdrop out of the one
  /// response, so asking for logo and banner together is one network call,
  /// not two. Keyed on [key] (shared with the logo/banner caches) and
  /// deduplicated across concurrent callers — the hero's logo lookup and
  /// banner lookup for the same title land on the same in-flight request.
  ///
  /// Failures (timeout, TMDB reset, …) propagate to every caller awaiting
  /// this key — each of [_tmdbLogoFor]/[bannerFor] catches its own and skips
  /// caching, so a transient failure isn't mistaken for a genuine "no image"
  /// and locked in forever.
  Future<_TmdbImages> _images(MediaItem item, String key) {
    return _tmdbLookups.putIfAbsent(
      key,
      () => _fetchImages(item).timeout(const Duration(seconds: 5)).whenComplete(
        () {
          _tmdbLookups.remove(key);
        },
      ),
    );
  }

  Future<_TmdbImages> _fetchImages(MediaItem item) async {
    int? id = item.tmdbId;
    var isTv = item.tmdbIsTv;
    if (id == null) {
      final q = (item.englishTitle ?? item.title).trim();
      if (q.isEmpty) return const _TmdbImages();
      final s = await _dio.get<dynamic>(
        '${Tmdb.base}/search/multi',
        queryParameters: {'query': q},
        options: Options(validateStatus: (c) => c != null && c < 500),
      );
      final results = (s.data is Map) ? s.data['results'] : null;
      if (results is! List) return const _TmdbImages();
      // Anime is almost always a TV entry on TMDB, never a movie — but
      // search/multi ranks by TMDB's own popularity, so a same-named movie
      // can outrank the actual series and we'd grab ITS art instead. For an
      // anime item, scan every result for a tv match before settling for
      // whichever (movie or tv) came first.
      final preferTv = item.type == ProviderType.anime;
      Map<dynamic, dynamic>? movie;
      for (final r in results) {
        if (r is! Map) continue;
        final mt = r['media_type'];
        if (mt == 'tv') {
          id = (r['id'] as num?)?.toInt();
          isTv = true;
          break;
        }
        if (mt == 'movie') {
          movie ??= r;
          if (!preferTv) break;
        }
      }
      if (id == null && movie != null) {
        id = (movie['id'] as num?)?.toInt();
        isTv = false;
      }
      if (id == null) return const _TmdbImages();
    }
    final kind = isTv ? 'tv' : 'movie';
    final imgs = await _dio.get<dynamic>(
      '${Tmdb.base}/$kind/$id/images',
      queryParameters: {'include_image_language': 'en,null'},
      options: Options(validateStatus: (c) => c != null && c < 500),
    );
    final data = imgs.data is Map ? imgs.data as Map : const {};

    final logos = data['logos'];
    String? logo;
    if (logos is List) {
      // Prefer an English logo; else the first available.
      Map<dynamic, dynamic>? best;
      for (final l in logos) {
        if (l is! Map) continue;
        if (l['iso_639_1'] == 'en') {
          best = l;
          break;
        }
        best ??= l;
      }
      final path = best?['file_path'] as String?;
      if (path != null && path.isNotEmpty) logo = '${Tmdb.img}/w500$path';
    }

    // The hero and Detail banner want a plain backdrop: the title is drawn on
    // top as a logo or text, so a picture with the title printed into it shows
    // it twice. Prefer a backdrop with no language (no text on it), then the
    // best-voted one (TMDB already orders these by vote), and only fall back to
    // a poster when TMDB has no backdrop at all.
    String? lead(dynamic list, {bool textless = false}) {
      if (list is! List || list.isEmpty) return null;
      Object? pick = list.first;
      if (textless) {
        for (final e in list) {
          if (e is Map && e['iso_639_1'] == null) {
            pick = e;
            break;
          }
        }
      }
      final path = pick is Map ? pick['file_path'] as String? : null;
      return path != null && path.isNotEmpty
          ? '${Tmdb.img}/original$path'
          : null;
    }

    final banner =
        lead(data['backdrops'], textless: true) ?? lead(data['posters']);

    return _TmdbImages(logo: logo, banner: banner);
  }
}

class _TmdbImages {
  const _TmdbImages({this.logo, this.banner});
  final String? logo;
  final String? banner;
}
