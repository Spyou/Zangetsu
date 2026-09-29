import 'package:dio/dio.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import 'base_provider.dart';

class StremioCatalog {
  const StremioCatalog({
    required this.type,
    required this.id,
    required this.name,
    this.extra = const [],
  });

  final String type;
  final String id;
  final String name;
  final List<String> extra;

  factory StremioCatalog.fromJson(Map<String, dynamic> json) {
    final extra =
        (json['extra'] as List?)
            ?.whereType<Map>()
            .map((e) => '${e['name'] ?? ''}')
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];
    return StremioCatalog(
      type: '${json['type'] ?? ''}',
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['id'] ?? ''}',
      extra: extra,
    );
  }
}

class StremioManifest {
  const StremioManifest({
    required this.id,
    required this.name,
    required this.catalogs,
    this.description,
  });

  final String id;
  final String name;
  final String? description;
  final List<StremioCatalog> catalogs;

  factory StremioManifest.fromJson(Map<String, dynamic> json) {
    return StremioManifest(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['id'] ?? 'Stremio addon'}',
      description: json['description'] as String?,
      catalogs:
          (json['catalogs'] as List?)
              ?.whereType<Map>()
              .map((e) => StremioCatalog.fromJson(Map<String, dynamic>.from(e)))
              .where((e) => e.type.isNotEmpty && e.id.isNotEmpty)
              .toList() ??
          const [],
    );
  }
}

/// Stremio addon protocol client. Addons are HTTP resources, not APKs: the
/// canonical endpoints are `/manifest.json`, `/catalog/{type}/{id}.json`,
/// `/meta/{type}/{id}.json`, and `/stream/{type}/{id}.json`.
class StremioProvider implements BaseProvider {
  StremioProvider({required String baseUrl, required Dio dio})
    : baseUrl = normalizeBase(baseUrl),
      _dio = dio,
      _manifestFuture = dio
          .get<Map<String, dynamic>>(
            '${normalizeBase(baseUrl)}/manifest.json',
            options: Options(responseType: ResponseType.json),
          )
          .then(
            (response) => StremioManifest.fromJson(
              Map<String, dynamic>.from(response.data ?? const {}),
            ),
          );

  final String baseUrl;
  final Dio _dio;
  final Future<StremioManifest> _manifestFuture;

  static String normalizeBase(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    if (result.endsWith('/manifest.json')) {
      result = result.substring(0, result.length - '/manifest.json'.length);
    }
    return result;
  }

  static String _encode(String value) => Uri.encodeComponent(value);

  static String _resourceKey(String type, String id) => '$type|$id';

  static ({String type, String id}) _parseResourceKey(String value) {
    final separator = value.indexOf('|');
    if (separator <= 0) return (type: 'series', id: value);
    return (
      type: value.substring(0, separator),
      id: value.substring(separator + 1),
    );
  }

  @override
  String get sourceId => 'stremio:${baseUrl.hashCode.toRadixString(16)}';

  @override
  String get displayName => 'Stremio · ${baseUrlUri.host}';

  Uri get baseUrlUri => Uri.parse(baseUrl);

  @override
  Future<ProviderInfo> getInfo() async => ProviderInfo(
    name: displayName,
    lang: '',
    baseUrl: baseUrl,
    type: ProviderType.movie,
  );

  Future<StremioManifest> get manifest => _manifestFuture;

  Future<List<MediaItem>> catalog(
    StremioCatalog catalog, {
    String? extra,
  }) async {
    final suffix = extra == null || extra.isEmpty ? '' : '/${_encode(extra)}';
    final response = await _dio.get<Map<String, dynamic>>(
      '$baseUrl/catalog/${_encode(catalog.type)}/${_encode(catalog.id)}$suffix.json',
    );
    final metas = (response.data?['metas'] as List?) ?? const [];
    return metas
        .whereType<Map>()
        .map((raw) {
          final json = Map<String, dynamic>.from(raw);
          final type = '${json['type'] ?? catalog.type}';
          return MediaItem(
            id: _resourceKey(type, '${json['id'] ?? ''}'),
            title: '${json['name'] ?? json['id'] ?? ''}',
            cover: json['poster'] as String?,
            url: _resourceKey(type, '${json['id'] ?? ''}'),
            sourceId: sourceId,
            type: type == 'series' ? ProviderType.movie : ProviderType.movie,
          );
        })
        .where((item) => item.id.isNotEmpty && item.title.isNotEmpty)
        .toList();
  }

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async {
    final addon = await manifest;
    final sections = <HomeSection>[];
    for (final catalog in addon.catalogs) {
      final items = await this.catalog(catalog);
      if (items.isNotEmpty) {
        sections.add(
          HomeSection(
            title: catalog.name,
            items: items,
            more: BrowseMore(
              sourceId: sourceId,
              kind: 'stremio_catalog:${catalog.type}:${catalog.id}',
            ),
          ),
        );
      }
    }
    return sections;
  }

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    final addon = await manifest;
    final catalog = addon.catalogs.firstOrNull;
    return catalog == null ? const [] : this.catalog(catalog);
  }

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) async {
    final addon = await manifest;
    if (addon.catalogs.isEmpty) return const [];
    final catalog = addon.catalogs.firstWhere(
      (c) => c.extra.contains('search'),
      orElse: () => addon.catalogs.first,
    );
    return this.catalog(catalog, extra: query);
  }

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
    final resource = _parseResourceKey(url);
    final response = await _dio.get<Map<String, dynamic>>(
      '$baseUrl/meta/${_encode(resource.type)}/${_encode(resource.id)}.json',
    );
    final meta = Map<String, dynamic>.from(
      response.data?['meta'] as Map? ?? const {},
    );
    final videos = (meta['videos'] as List?)?.whereType<Map>() ?? const <Map>[];
    final episodes =
        videos
            .map((video) => _episodeFromVideo(video, resource.type))
            .where((e) => e != null)
            .cast<Episode>()
            .toList()
          ..sort((a, b) {
            final season = (a.season ?? 1).compareTo(b.season ?? 1);
            return season != 0
                ? season
                : (a.number ?? 0).compareTo(b.number ?? 0);
          });
    return MediaDetail(
      id: '${meta['id'] ?? resource.id}',
      title: '${meta['name'] ?? resource.id}',
      cover: meta['poster'] as String?,
      url: url,
      description: meta['description'] as String?,
      episodes: episodes,
      type: ProviderType.movie,
      sourceId: sourceId,
      year: meta['year']?.toString(),
    );
  }

  Episode? _episodeFromVideo(Map raw, String type) {
    final season = (raw['season'] as num?)?.toInt();
    final episode = (raw['episode'] as num?)?.toDouble();
    if (season == null || episode == null) return null;
    final id = '${raw['id'] ?? 's${season}e$episode'}';
    final resourceId = _resourceKey(type, id);
    return Episode(
      id: id,
      title: '${raw['name'] ?? 'Season $season Episode ${episode.toInt()}'}',
      number: episode,
      season: season,
      url: resourceId,
      thumbnail: raw['thumbnail'] as String?,
    );
  }

  @override
  Future<List<Episode>> getEpisodes(
    String url, {
    String category = 'sub',
  }) async => (await getDetail(url, category: category)).episodes;

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) async {
    final resource = _parseResourceKey(episodeUrl);
    final response = await _dio.get<Map<String, dynamic>>(
      '$baseUrl/stream/${_encode(resource.type)}/${_encode(resource.id)}.json',
    );
    final streams = (response.data?['streams'] as List?) ?? const [];
    return streams
        .whereType<Map>()
        .map((raw) {
          final json = Map<String, dynamic>.from(raw);
          final url = '${json['url'] ?? ''}';
          final headers = <String, String>{};
          final hints = json['behaviorHints'];
          if (hints is Map && hints['proxyHeaders'] is Map) {
            final request = (hints['proxyHeaders'] as Map)['request'];
            if (request is Map) {
              headers.addAll(request.map((k, v) => MapEntry('$k', '$v')));
            }
          }
          return VideoSource(
            url: url,
            quality: json['name'] as String?,
            headers: headers.isEmpty ? null : headers,
          );
        })
        .where((source) => source.url.startsWith('http'))
        .toList();
  }
}
