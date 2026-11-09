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
import 'package:zangetsu_source_bridge/stremio.dart';

/// The one provider the app registers for Stremio. It owns every enabled addon
/// internally so saved titles use one source id and one external id.
class StremioProvider implements BaseProvider {
  StremioProvider(this.manager);

  final StremioManager manager;

  @override
  String get sourceId => stremioSourceId;

  @override
  String get displayName => 'Stremio';

  List<StremioInstallation> get _enabled => manager.enabled;

  @override
  Future<ProviderInfo> getInfo() async => const ProviderInfo(
    name: 'Stremio',
    lang: 'en',
    baseUrl: '',
    type: ProviderType.movie,
    version: '1.0.0',
  );

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async {
    final sections = <HomeSection>[];
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
      if (jobs.isNotEmpty) break;
    }
    for (var offset = 0; offset < jobs.length; offset += 4) {
      final batch = jobs.skip(offset).take(4);
      final rows = await Future.wait(
        batch.map((job) async {
          final (installation, catalog) = job;
          final items = await _loadCatalog(
            installation,
            catalog,
            search: null,
            skip: 0,
          );
          if (items.isEmpty) return null;
          final duplicateName =
              jobs.where((j) => j.$2.name == catalog.name).length > 1;
          return HomeSection(
            title: duplicateName
                ? '${catalog.name} · ${catalog.type == 'series' ? 'Series' : 'Movies'}'
                : catalog.name,
            items: items,
            more: BrowseMore(
              sourceId: stremioSourceId,
              kind: 'stremio_catalog',
              categoryId: jsonEncode({
                'i': installation.id,
                't': catalog.type,
                'c': catalog.id,
              }),
            ),
          );
        }),
      );
      sections.addAll(rows.whereType<HomeSection>());
    }
    return sections;
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
    final session = manager.openLinks(ref);
    try {
      await session.done;
      final sources = <VideoSource>[];
      final seen = <String>{};
      for (final group in session.currentGroups) {
        for (final choice in group.choices) {
          if (!session.isCurrent(choice)) continue;
          final source = stremioVideoSource(choice, allowTorrent: allowTorrent);
          if (source != null && seen.add(source.url)) sources.add(source);
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
    Exception? failure;
    for (final installation in candidates) {
      try {
        final meta = await manager.meta(
          installation.id,
          type: ref.type,
          itemId: ref.itemId,
        );
        if (meta != null) return meta;
      } on StremioFailure catch (error) {
        failure = error;
      } on StremioInstallException catch (error) {
        failure = error;
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
      );
      return page.metas
          .map((meta) => _item(installation, catalog, meta))
          .toList(growable: false);
    } catch (_) {
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
