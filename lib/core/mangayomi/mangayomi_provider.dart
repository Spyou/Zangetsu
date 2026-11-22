import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/page_content.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import '../provider/base_provider.dart';
import '../provider/reading_provider.dart';
import '../torrent/torrent_util.dart';
import 'mangayomi_manager.dart';

const MethodChannel _mangayomiCloudflareChannel = MethodChannel(
  'AniAura/mihon',
);

class MangayomiProvider implements BaseProvider, ReadingProvider {
  MangayomiProvider({required this.manager, required this.installed});

  final MangayomiManager manager;
  final InstalledMangayomiSource installed;
  final Map<String, String> _chapterNames = {};

  MangayomiSource get source => installed.source;

  @override
  String get sourceId => source.key;

  @override
  String get displayName => source.name;

  ProviderType get type => switch (source.contentType) {
    MangayomiContentType.manga => ProviderType.manga,
    MangayomiContentType.video => ProviderType.anime,
    MangayomiContentType.novel => ProviderType.novel,
  };

  @override
  Future<ProviderInfo> getInfo() async => ProviderInfo(
    name: source.name,
    lang: source.language,
    baseUrl: source.baseUrl.toString(),
    logo: source.iconUrl?.toString(),
    type: type,
    version: source.version,
  );

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async {
    Object? popularFailure;
    StackTrace? popularStackTrace;
    final results = await Future.wait([
      popular().catchError((Object error, StackTrace stackTrace) {
        popularFailure = error;
        popularStackTrace = stackTrace;
        return <MediaItem>[];
      }),
      latest().catchError((_) => <MediaItem>[]),
    ]);
    final items = results[0];
    final updates = results[1];
    if (items.isEmpty && updates.isEmpty && popularFailure != null) {
      Error.throwWithStackTrace(popularFailure!, popularStackTrace!);
    }
    return [
      if (items.isNotEmpty)
        HomeSection(
          title: 'Popular',
          items: items,
          more: BrowseMore(sourceId: sourceId, kind: 'mg_popular'),
        ),
      if (updates.isNotEmpty)
        HomeSection(
          title: 'Latest',
          items: updates,
          more: BrowseMore(sourceId: sourceId, kind: 'mg_latest'),
        ),
    ];
  }

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) => manager.run(sourceId, (worker) async {
    final result = await worker.getPopular(page);
    return [
      for (final manga in result.list)
        if ((manga.link ?? '').isNotEmpty)
          MangayomiMapping.item(source, manga, type),
    ];
  });

  Future<List<MediaItem>> latest({int page = 1}) =>
      manager.run(sourceId, (worker) async {
        final result = await worker.getLatestUpdates(page);
        return [
          for (final manga in result.list)
            if ((manga.link ?? '').isNotEmpty)
              MangayomiMapping.item(source, manga, type),
        ];
      });

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
    String? filtersJson,
  }) => manager.run(sourceId, (worker) async {
    final filters = filtersJson == null || filtersJson.isEmpty
        ? const <dynamic>[]
        : jsonDecode(filtersJson) as List;
    final result = await worker.search(query, page, filters);
    return [
      for (final manga in result.list)
        if ((manga.link ?? '').isNotEmpty)
          MangayomiMapping.item(source, manga, type),
    ];
  });

  Future<List<Map<String, dynamic>>> getFilters() => manager.run(
    sourceId,
    (worker) async => [
      for (final item in await worker.getFilterList())
        if (item is Map) Map<String, dynamic>.from(item),
    ],
  );

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) =>
      manager.run(sourceId, (worker) async {
        final manga = await worker.getDetail(url);
        final chapters = manga.chapters ?? const <MChapter>[];
        final episodes = MangayomiMapping.episodes(source, chapters);
        _rememberChapters(chapters);
        return MangayomiMapping.detail(source, manga, type, url, episodes);
      });

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) =>
      manager.run(sourceId, (worker) async {
        final manga = await worker.getDetail(url);
        final chapters = manga.chapters ?? const <MChapter>[];
        final episodes = MangayomiMapping.episodes(source, chapters);
        _rememberChapters(chapters);
        return episodes;
      });

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) => manager.run(sourceId, (worker) async {
    final videos = await worker.getVideoList(episodeUrl);
    final headersByHost = await _cloudflareHeadersByHost(
      videos.map((video) => video.url),
    );
    final sources = <VideoSource>[];
    for (final video in videos) {
      if (video.url.isEmpty) continue;
      final host = Uri.tryParse(video.url)?.host;
      sources.add(
        MangayomiMapping.video(
          source,
          video,
          headers: _mergeHeaders(
            video.headers,
            host == null ? const {} : headersByHost[host] ?? const {},
          ),
        ),
      );
    }
    return sources;
  });

  @override
  Future<List<PageImage>> getPages(String chapterUrl) =>
      manager.run(sourceId, (worker) async {
        final pages = await worker.getPageList(chapterUrl);
        final mapped = [
          for (final page in pages)
            if (page.url.isNotEmpty) MangayomiMapping.page(source, page),
        ];
        final headersByHost = await _cloudflareHeadersByHost(
          mapped.map((page) => page.url),
        );
        return [
          for (final page in mapped)
            PageImage(
              url: page.url,
              headers: _mergeHeaders(
                page.headers,
                headersByHost[Uri.tryParse(page.url)?.host] ?? const {},
              ),
            ),
        ];
      });

  Future<Map<String, Map<String, String>>> _cloudflareHeadersByHost(
    Iterable<String> urls,
  ) async {
    if (!source.hasCloudflare) return const {};
    final urlsByHost = <String, String>{};
    for (final url in urls) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        continue;
      }
      urlsByHost.putIfAbsent(uri.host, () => url);
    }
    final entries = await Future.wait(
      urlsByHost.entries.map(
        (entry) async =>
            MapEntry(entry.key, await _cloudflareHeaders(entry.value)),
      ),
    );
    return Map.fromEntries(entries);
  }

  Future<Map<String, String>> _cloudflareHeaders(String url) async {
    if (!source.hasCloudflare) return const {};
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return const {};
    }
    try {
      final result = await _mangayomiCloudflareChannel
          .invokeMapMethod<String, String>('imageCookie', {'url': url});
      if (result?['Cookie']?.isNotEmpty != true) return const {};
      return result!;
    } on MissingPluginException {
      // A missing cookie bridge must not block the source.
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  Map<String, String>? _mergeHeaders(
    Map<String, String>? extensionHeaders,
    Map<String, String> cloudflareHeaders,
  ) {
    if (cloudflareHeaders.isEmpty) return extensionHeaders;
    final headers = <String, String>{...?extensionHeaders};
    String? existingKey(String name) {
      for (final key in headers.keys) {
        if (key.toLowerCase() == name) return key;
      }
      return null;
    }

    final cookieKey = existingKey('cookie');
    final existingCookie = cookieKey == null ? null : headers.remove(cookieKey);
    final clearance = cloudflareHeaders['Cookie']!;
    headers['Cookie'] = existingCookie == null || existingCookie.isEmpty
        ? clearance
        : '$clearance; $existingCookie';
    if (existingKey('user-agent') == null) {
      final userAgent = cloudflareHeaders['User-Agent'];
      if (userAgent != null) headers['User-Agent'] = userAgent;
    }
    return headers;
  }

  @override
  Future<ChapterText> getText(String chapterUrl) =>
      manager.run(sourceId, (worker) async {
        final html = await worker.getHtmlContent(
          _chapterNames[chapterUrl] ?? '',
          chapterUrl,
        );
        return ChapterText(html: html);
      });

  void _rememberChapters(List<MChapter> chapters) {
    for (final chapter in chapters) {
      final url = chapter.url;
      if (url != null && url.isNotEmpty) {
        _chapterNames[url] = chapter.name ?? '';
      }
    }
  }
}

abstract final class MangayomiMapping {
  static MediaItem item(
    MangayomiSource source,
    MManga manga,
    ProviderType type,
  ) {
    final url = manga.link ?? '';
    return MediaItem(
      id: url,
      title: manga.name ?? '',
      cover: _resolveNullable(source, manga.imageUrl),
      url: url,
      type: type,
      sourceId: source.key,
      genres: manga.genre ?? const [],
      status: _status(manga.status),
    );
  }

  static MediaDetail detail(
    MangayomiSource source,
    MManga manga,
    ProviderType type,
    String requestedUrl,
    List<Episode> episodes,
  ) => MediaDetail(
    id: manga.link ?? requestedUrl,
    title: manga.name ?? '',
    cover: _resolveNullable(source, manga.imageUrl),
    url: manga.link ?? requestedUrl,
    description: manga.description,
    status: _status(manga.status) ?? MediaStatus.unknown,
    genres: manga.genre ?? const [],
    studios: [
      if ((manga.author ?? '').isNotEmpty) manga.author!,
      if ((manga.artist ?? '').isNotEmpty && manga.artist != manga.author)
        manga.artist!,
    ],
    episodes: episodes,
    type: type,
    sourceId: source.key,
  );

  static List<Episode> episodes(
    MangayomiSource source,
    List<MChapter> chapters,
  ) {
    final episodes = [
      for (var index = 0; index < chapters.length; index++)
        if ((chapters[index].url ?? '').isNotEmpty)
          Episode(
            id: chapters[index].url!,
            title: chapters[index].name ?? 'Chapter ${index + 1}',
            number: _number(chapters[index].name),
            url: chapters[index].url!,
            date: _uploadDate(chapters[index].dateUpload),
            thumbnail: _resolveNullable(source, chapters[index].thumbnailUrl),
            filler: chapters[index].isFiller ?? false,
            scanlator: chapters[index].scanlator,
          ),
    ];
    if (episodes.length < 2) return episodes;
    if (episodes.any((episode) => episode.number == null)) return episodes;
    episodes.sort((a, b) => a.number!.compareTo(b.number!));
    return episodes;
  }

  static String? _uploadDate(String? value) {
    if (value == null) return null;
    final timestamp = int.tryParse(value.trim());
    if (timestamp == null || timestamp < 100000000) return value;

    final milliseconds = timestamp < 100000000000
        ? timestamp * 1000
        : timestamp;
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
      ).toIso8601String();
    } on RangeError {
      return value;
    }
  }

  static PageImage page(MangayomiSource source, MPage page) =>
      PageImage(url: _resolve(source, page.url), headers: page.headers);

  static VideoSource video(
    MangayomiSource source,
    MVideo video, {
    Map<String, String>? headers,
  }) {
    final url = video.url;
    return VideoSource(
      url: url,
      quality: video.quality.isEmpty ? null : video.quality,
      label: video.quality.isEmpty ? null : video.quality,
      container: _container(url),
      headers: headers ?? video.headers,
      subtitles: [
        for (final track in video.subtitles ?? const <Track>[])
          if ((track.file ?? '').isNotEmpty)
            Subtitle(
              url: _resolve(source, track.file!),
              lang: track.label ?? '',
              label: track.label,
              format: _extension(track.file!),
            ),
      ],
    );
  }

  static String _resolve(MangayomiSource source, String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.hasScheme || value.isEmpty) return value;
    return source.baseUrl.resolveUri(uri).toString();
  }

  static String? _resolveNullable(MangayomiSource source, String? value) =>
      value == null || value.isEmpty ? null : _resolve(source, value);

  static MediaStatus? _status(MStatus? status) => switch (status) {
    MStatus.ongoing => MediaStatus.ongoing,
    MStatus.completed || MStatus.publishingFinished => MediaStatus.completed,
    MStatus.canceled => MediaStatus.cancelled,
    MStatus.onHiatus => MediaStatus.hiatus,
    MStatus.unknown || null => null,
  };

  static double? _number(String? name) {
    final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(name ?? '');
    return match == null ? null : double.tryParse(match.group(0)!);
  }

  static SourceContainer _container(String url) {
    if (isTorrentUrl(url)) return SourceContainer.torrent;
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.m3u8')) return SourceContainer.hls;
    if (path.endsWith('.mp4')) return SourceContainer.mp4;
    if (path.endsWith('.torrent')) return SourceContainer.torrent;
    return SourceContainer.unknown;
  }

  static String? _extension(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    return dot < 0 ? null : path.substring(dot + 1).toLowerCase();
  }
}
