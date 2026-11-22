import 'dart:convert';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import '../provider/base_provider.dart';
import 'stremio_manager.dart';
import 'stremio_ref.dart';
import 'stremio_stream_mapping.dart';
import 'package:AniAura_source_bridge/stremio.dart';

/// Retains only catalogues that failed, while accepting genuinely empty results.
List<HomeSection> retainFailedStremioRows(
  List<HomeSection> fresh,
  List<HomeSection> previous,
  Set<String> failed,
) {
  if (failed.isEmpty || previous.isEmpty) return fresh;
  final pending = {
    for (final row in fresh) row.more?.categoryId ?? row.title: row,
  };
  final rows = <HomeSection>[];
  for (final row in previous) {
    final key = row.more?.categoryId ?? row.title;
    final updated = pending.remove(key);
    if (updated != null) {
      rows.add(updated);
    } else if (failed.contains(key)) {
      rows.add(row);
    }
  }
  return [...rows, ...pending.values];
}

/// The one provider the app registers for Stremio. It owns every enabled addon
/// internally so saved titles use one source id and one external id.
class StremioProvider implements BaseProvider {
  StremioProvider(this.manager);

  final StremioManager manager;

  ({
    String url,
    bool allowTorrent,
    int revision,
    DateTime at,
    Future<List<VideoSource>> sources,
  })?
  _prefetched;

  Future<void> prefetchVideoSources(
    String url, {
    bool allowTorrent = false,
  }) async {
    final previous = _prefetched;
    if (previous != null &&
        previous.url == url &&
        previous.allowTorrent == allowTorrent &&
        previous.revision == manager.revision &&
        DateTime.now().difference(previous.at) < const Duration(minutes: 2)) {
      await previous.sources;
      return;
    }
    final future = getVideoSources(
      url,
      allowTorrent: allowTorrent,
    ).catchError((_) => <VideoSource>[]);
    _prefetched = (
      url: url,
      allowTorrent: allowTorrent,
      revision: manager.revision,
      at: DateTime.now(),
      sources: future,
    );
    await future;
  }

  @override
  String get sourceId => stremioSourceId;

  @override
  String get displayName => 'Stremio';

  List<StremioInstallation> get _enabled => manager.enabled;

  Future<String?> titleLogoFor(MediaItem item) async =>
      (await _metadataFor(StremioRef.parse(item.url)))?.logo;

  @override
  Future<ProviderInfo> getInfo() async => const ProviderInfo(
    name: 'Stremio',
    lang: 'en',
    baseUrl: '',
    type: ProviderType.movie,
    version: '1.0.0',
  );

  @override
  Future<List<HomeSection>?> getHome({
    String category = 'sub',
    void Function(List<HomeSection>)? onSections,
    bool forceRefresh = false,
    void Function(String categoryId)? onFailure,
  }) async {
    final jobs = <(StremioInstallation, StremioCatalog)>[];
    for (final installation in _enabled) {
      if (!installation.supports('catalog')) continue;
      var catalogs = installation.catalogs;
      if (installation.id == StremioManager.defaultMetadataId) {
        try {
          catalogs = (await manager.manifest(installation.id)).catalogs;
        } on StremioFailure {
          // Keep the startup snapshot available during a manifest outage.
        } on StremioInstallException {
          // The installed snapshot remains usable if secure storage is unavailable.
        }
      }
      for (final catalog in catalogs) {
        if (!catalog.extras.any((e) => e.isRequired) &&
            installation.isCatalogVisible(catalog.type, catalog.id)) {
          jobs.add((installation, catalog));
        }
      }
    }
    final rows = List<HomeSection?>.filled(jobs.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final index = next++;
        final (installation, catalog) = jobs[index];
        final categoryId = jsonEncode({
          'i': installation.id,
          't': catalog.type,
          'c': catalog.id,
        });
        final items = await _loadCatalog(
          installation,
          catalog,
          search: null,
          skip: 0,
          forceRefresh: forceRefresh,
          onFailure: () => onFailure?.call(categoryId),
        );
        if (items.isEmpty) continue;
        final duplicateName =
            jobs
                .where(
                  (job) =>
                      job.$1.id == installation.id &&
                      job.$2.name == catalog.name,
                )
                .length >
            1;
        rows[index] = HomeSection(
          title: duplicateName
              ? '${catalog.name} · ${catalog.type == 'series' ? 'Series' : 'Movies'}'
              : catalog.name,
          items: items,
          more: BrowseMore(
            sourceId: stremioSourceId,
            kind: 'stremio_catalog',
            categoryId: categoryId,
          ),
        );
        onSections?.call(List.unmodifiable(rows.whereType<HomeSection>()));
      }
    }

    await Future.wait(List.generate(jobs.length.clamp(0, 4), (_) => worker()));
    return rows.whereType<HomeSection>().toList(growable: false);
  }

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    final items = <MediaItem>[];
    for (final installation in _enabled) {
      for (final catalog in installation.catalogs) {
        items.addAll(
          await _loadCatalog(
            installation,
            catalog,
            search: null,
            skip: page <= 1 ? 0 : (page - 1) * 100,
          ),
        );
      }
    }
    return _distinct(items);
  }

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) async {
    final items = <MediaItem>[];
    for (final installation in _enabled) {
      for (final catalog in installation.catalogs) {
        if (!catalog.isSearchable) continue;
        if (page > 1 && !catalog.isPaged) continue;
        items.addAll(
          await _loadCatalog(
            installation,
            catalog,
            search: query,
            skip: page <= 1 ? 0 : (page - 1) * 100,
          ),
        );
      }
    }
    return _distinct(items);
  }

  static bool supportsSearchCatalog(StremioCatalog catalog) =>
      catalog.isSearchable &&
      !catalog.extras.any(
        (extra) =>
            extra.isRequired &&
            extra.name != 'search' &&
            (extra.name != 'genre' || extra.options.isEmpty),
      );

  static bool supportsBrowseCatalog(StremioCatalog catalog) =>
      !catalog.extras.any(
        (extra) =>
            extra.isRequired &&
            (extra.name != 'genre' ||
                extra.options.every((option) => option.isEmpty)),
      );

  Future<List<MediaItem>> browseCatalog({
    required String installationId,
    required String type,
    required String catalogId,
    required int page,
    String? genre,
  }) async {
    final addon = manager.byId(installationId);
    if (addon == null || !addon.enabled) {
      throw const StremioInstallException('Addon is no longer available');
    }
    final catalog = addon.catalogs
        .where((c) => c.type == type && c.id == catalogId)
        .firstOrNull;
    if (catalog == null || !supportsBrowseCatalog(catalog)) {
      throw const StremioInstallException('Catalogue is no longer available');
    }
    if (page > 1 && !catalog.isPaged) return const [];
    final extra = catalog.extras.where((e) => e.name == 'genre').firstOrNull;
    if (genre != null && !(extra?.options.contains(genre) ?? false)) {
      throw const StremioInstallException('Genre is no longer available');
    }
    final selectedGenre =
        genre ??
        (extra?.isRequired == true
            ? extra!.options.firstWhere((option) => option.isNotEmpty)
            : null);
    final result = await manager.catalog(
      addon.id,
      type: catalog.type,
      catalogId: catalog.id,
      genre: selectedGenre,
      skip: page > 1 ? (page - 1) * 100 : null,
    );
    final current = manager.byId(addon.id);
    if (current == null ||
        !current.enabled ||
        current.revision != addon.revision) {
      throw const StremioInstallException('Addon changed while loading');
    }
    return _distinct(
      result.metas.map((meta) => _item(addon, catalog, meta)).toList(),
    );
  }

  /// Searches catalogue rows in bounded batches, preserving their addon.
  Stream<({String id, String name, String category, List<MediaItem> items})>
  searchAddons(String query) async* {
    final jobs = <(StremioInstallation, StremioCatalog)>[];
    for (final addon in _enabled) {
      for (final catalog in addon.catalogs) {
        if (!supportsSearchCatalog(catalog)) continue;
        jobs.add((addon, catalog));
      }
    }
    for (var start = 0; start < jobs.length; start += 4) {
      final results = Stream.fromFutures(
        jobs.skip(start).take(4).map((job) async {
          final (addon, catalog) = job;
          final duplicateName = addon.catalogs.any(
            (other) =>
                supportsSearchCatalog(other) &&
                other.type != catalog.type &&
                other.name.trim().toLowerCase() ==
                    catalog.name.trim().toLowerCase(),
          );
          final typeName = switch (catalog.type) {
            'movie' => 'Movies',
            'series' => 'Series',
            _ => catalog.type,
          };
          final category = duplicateName && typeName.isNotEmpty
              ? '${catalog.name} · $typeName'
              : catalog.name;
          final items = await _loadCatalog(
            addon,
            catalog,
            search: query,
            skip: 0,
          ).timeout(const Duration(seconds: 8), onTimeout: () => <MediaItem>[]);
          return (
            id: addon.id,
            name: addon.name,
            category: category,
            items: _distinct(items),
          );
        }),
      );
      await for (final result in results) {
        if (manager.byId(result.id)?.enabled == true) yield result;
      }
    }
  }

  /// One page of a catalogue for the Home "See all" grid. The handle stored
  /// on [HomeSection.more] carries installation + type + catalogue id.
  Future<List<MediaItem>> catalogPage({
    required String installationId,
    required String type,
    required String catalogId,
    required int page,
  }) async {
    final installation = manager.byId(installationId);
    if (installation == null) return const [];
    final catalog = installation.catalogs.firstWhere(
      (c) => c.id == catalogId && c.type == type,
      orElse: () => StremioCatalog(type: type, id: catalogId, name: catalogId),
    );
    return _loadCatalog(
      installation,
      catalog,
      search: null,
      skip: page <= 1 ? 0 : (page - 1) * 100,
    );
  }

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
    final ref = StremioRef.parse(url);
    final meta = await _metadataFor(ref);
    if (meta == null) {
      throw const StremioInstallException('title is unavailable');
    }
    final mediaType = meta.type.isEmpty ? ref.type : meta.type;
    return MediaDetail(
      id: stremioMediaId(
        type: mediaType,
        itemId: ref.itemId,
        installationId: ref.installationId,
      ),
      title: meta.name,
      cover: meta.poster,
      banner: meta.background,
      url: url,
      description: meta.description,
      genres: meta.genres,
      episodes: _episodes(ref, meta),
      year: _yearOf(meta.releaseInfo),
      type: ProviderType.movie,
      sourceId: stremioSourceId,
      malId: int.tryParse(meta.externalId('mal') ?? ''),
      tmdbId: int.tryParse(meta.externalId('tmdb') ?? ''),
      tmdbIsTv: !isStremioMovieType(mediaType),
      imdbId: meta.externalId('imdb'),
      hasScheduledVideos: meta.hasScheduledVideos,
    );
  }

  @override
  Future<List<Episode>> getEpisodes(
    String url, {
    String category = 'sub',
  }) async {
    final ref = StremioRef.parse(url);
    final meta = await _metadataFor(ref);
    if (meta == null) return const [];
    return _episodes(ref, meta);
  }

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
    bool allowTorrent = false,
  }) async {
    final ref = StremioRef.parse(episodeUrl);
    if (!manager.canOpen(ref)) {
      throw const StremioInstallException('addon is not installed');
    }
    final warmed = _prefetched;
    if (fast &&
        warmed != null &&
        warmed.url == episodeUrl &&
        warmed.allowTorrent == allowTorrent) {
      _prefetched = null;
      if (warmed.revision == manager.revision &&
          DateTime.now().difference(warmed.at) < const Duration(minutes: 2)) {
        final cached = await warmed.sources;
        if (warmed.revision == manager.revision && cached.isNotEmpty) {
          return cached;
        }
      }
    }
    final session = manager.openLinks(ref);
    try {
      await session.done;
      final sources = <VideoSource>[];
      final seen = <String>{};
      for (final group in session.currentGroups) {
        for (final choice in group.choices) {
          if (!session.isCurrent(choice)) continue;
          final source = stremioVideoSource(
            choice,
            streamAddonName: group.installation.name,
            allowTorrent: allowTorrent,
          );
          if (source != null && seen.add(source.url)) {
            manager.rememberSubtitleStream(ref, source.url, choice.stream);
            sources.add(source);
          }
        }
      }
      return sources;
    } finally {
      session.dispose();
    }
  }

  Future<StremioMeta?> _metadataFor(StremioRef ref) async {
    final origin = manager.byId(ref.installationId);
    final sharedId = isVerifiedStremioId(ref.itemId);
    if (origin == null && !sharedId) {
      throw const StremioInstallException('addon is not installed');
    }
    bool compatible(StremioInstallation installation) {
      final resource = installation.resource('meta');
      return installation.enabled &&
          resource != null &&
          (installation.types.isEmpty ||
              installation.types.contains(ref.type)) &&
          (installation.idPrefixes.isEmpty ||
              installation.idPrefixes.any(ref.itemId.startsWith)) &&
          resource.acceptsType(ref.type) &&
          resource.acceptsId(ref.itemId);
    }

    final candidates = [
      if (origin != null && compatible(origin)) origin,
      if (sharedId)
        for (final installation in _enabled)
          if (installation.id != origin?.id && compatible(installation))
            installation,
    ];
    Future<({StremioMeta? meta, Object? error, StackTrace? stack})> fetch(
      StremioInstallation installation,
    ) async {
      try {
        return (
          meta: await manager.meta(
            installation.id,
            type: ref.type,
            itemId: ref.itemId,
          ),
          error: null,
          stack: null,
        );
      } catch (error, stack) {
        return (meta: null, error: error, stack: stack);
      }
    }

    Exception? failure;
    for (var offset = 0; offset < candidates.length; offset += 4) {
      // Start fallbacks early, but keep the selected addon's metadata first.
      final attempts = candidates.skip(offset).take(4).map(fetch).toList();
      for (final attempt in attempts) {
        final result = await attempt;
        if (result.meta != null) return result.meta;
        final error = result.error;
        if (error is StremioFailure || error is StremioInstallException) {
          failure = error as Exception;
        } else if (error != null) {
          Error.throwWithStackTrace(error, result.stack!);
        }
      }
    }
    if (failure != null) throw failure;
    return null;
  }

  Future<List<MediaItem>> _loadCatalog(
    StremioInstallation installation,
    StremioCatalog catalog, {
    required String? search,
    required int skip,
    bool forceRefresh = false,
    void Function()? onFailure,
  }) async {
    try {
      final page = await manager.catalog(
        installation.id,
        type: catalog.type,
        catalogId: catalog.id,
        search: search,
        genre: catalog.extras
            .where(
              (e) => e.name == 'genre' && e.isRequired && e.options.isNotEmpty,
            )
            .firstOrNull
            ?.options
            .first,
        skip: skip > 0 ? skip : null,
        forceRefresh: forceRefresh,
      );
      return page.metas
          .map((meta) => _item(installation, catalog, meta))
          .toList(growable: false);
    } catch (_) {
      onFailure?.call();
      return const [];
    }
  }

  MediaItem _item(
    StremioInstallation installation,
    StremioCatalog catalog,
    StremioMetaPreview meta,
  ) {
    final type = meta.type.isEmpty ? catalog.type : meta.type;
    return MediaItem(
      id: stremioMediaId(
        type: type,
        itemId: meta.id,
        installationId: installation.id,
      ),
      title: meta.name,
      cover: meta.poster,
      banner: meta.background,
      titleLogo: meta.logo,
      posterShape: meta.posterShape,
      landscapePoster: meta.landscapePoster,
      url: StremioRef(
        installationId: installation.id,
        type: type,
        itemId: meta.id,
      ).encode(),
      type: ProviderType.movie,
      sourceId: stremioSourceId,
      imdbId: RegExp(r'^tt\d+$').hasMatch(meta.id) ? meta.id : null,
      tmdbId: int.tryParse(
        RegExp(r'^tmdb:(\d+)$').firstMatch(meta.id)?.group(1) ?? '',
      ),
    );
  }

  List<Episode> _episodes(StremioRef ref, StremioMeta meta) {
    if (meta.videos.isNotEmpty) {
      return meta.videos
          .map((video) => _episode(ref, video))
          .toList(growable: false);
    }

    final fallback = meta.defaultVideoId;
    if (fallback != null && fallback.isNotEmpty) {
      return [
        _episode(
          ref,
          StremioVideo(id: fallback, title: meta.name, season: 0, episode: 1),
        ),
      ];
    }

    if (isStremioMovieType(meta.type) || isStremioMovieType(ref.type)) {
      return [
        Episode(
          id: stremioEpisodeId(
            itemId: ref.itemId,
            videoId: ref.itemId,
            installationId: ref.installationId,
          ),
          title: meta.name,
          number: 1,
          url: StremioRef(
            installationId: ref.installationId,
            type: ref.type,
            itemId: ref.itemId,
          ).encode(),
        ),
      ];
    }
    // Live TV / channels carry no videos array by design — a channel IS the
    // stream, played via stream/{type}/{id} with no video id. Without a row
    // the detail screen dead-ends on "no episodes", so synthesize one playable
    // Live entry (same shape as the movie fallback above). Non-series types
    // are never gated on an episode list. ponytail: same shape, no machinery.
    if (isStremioChannelType(meta.type) || isStremioChannelType(ref.type)) {
      return [
        Episode(
          id: stremioEpisodeId(
            itemId: ref.itemId,
            videoId: ref.itemId,
            installationId: ref.installationId,
          ),
          title: meta.name,
          number: 1,
          url: StremioRef(
            installationId: ref.installationId,
            type: ref.type,
            itemId: ref.itemId,
          ).encode(),
        ),
      ];
    }
    return const [];
  }

  Episode _episode(StremioRef ref, StremioVideo video) {
    return Episode(
      id: stremioEpisodeId(
        itemId: ref.itemId,
        videoId: video.id,
        installationId: ref.installationId,
      ),
      title: video.title ?? 'Episode ${video.episode ?? ''}'.trim(),
      number: video.episode?.toDouble(),
      url: StremioRef(
        installationId: ref.installationId,
        type: ref.type,
        itemId: ref.itemId,
        videoId: video.id,
      ).encode(),
      date: video.released,
      thumbnail: video.thumbnail,
      season: video.season,
      description: video.overview,
      metaTitle: video.title,
    );
  }

  static List<MediaItem> _distinct(List<MediaItem> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(item.id)) item,
    ];
  }

  static String? _yearOf(String? releaseInfo) {
    if (releaseInfo == null) return null;
    return RegExp(r'\d{4}').firstMatch(releaseInfo)?.group(0);
  }
}
