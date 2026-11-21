import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/metadata/title_logo_service.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

/// Fake TMDB: `/search/multi` returns a same-named movie ranked ABOVE the
/// real tv series (mirrors TMDB's own popularity ranking), and `/images`
/// answers differently per media kind so a test can tell which one was used.
/// [failImagesTimes] makes the first N `/images` calls throw, to exercise the
/// "a network error must not be cached as a genuine miss" path.
class _Adapter implements HttpClientAdapter {
  final requests = <Uri>[];
  int failImagesTimes = 0;
  int _imagesCalls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requests.add(options.uri);
    final path = options.uri.path;
    if (path == '/3/search/multi') {
      return _json({
        'results': [
          {'id': 10, 'media_type': 'movie'},
          {'id': 20, 'media_type': 'tv'},
        ],
      });
    }
    if (path.contains('/images')) {
      _imagesCalls++;
      if (_imagesCalls <= failImagesTimes) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      final isTv = path.startsWith('/3/tv/');
      return _json({
        'logos': [],
        'posters': [
          {'file_path': isTv ? '/tv-poster.png' : '/movie-poster.png'},
        ],
        'backdrops': [],
      });
    }
    throw UnsupportedError('unexpected path $path');
  }

  ResponseBody _json(Map<String, dynamic> body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      'content-type': ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

MediaItem _animeItem({String title = 'Example Anime'}) => MediaItem(
  id: 'al:1',
  title: title,
  url: 'zm://anime/al:1',
  type: ProviderType.anime,
  sourceId: 'zm',
);

void main() {
  late Directory temp;
  late _Adapter adapter;
  late TitleLogoService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tmdb_banner');
    Hive.init(temp.path);
    await Hive.openBox<String>('logo_cache');
    await Hive.openBox<String>('tmdb_banner_cache_v3');
    adapter = _Adapter();
    service = TitleLogoService(Dio()..httpClientAdapter = adapter);
  });

  tearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test(
    'an anime banner prefers the tv match over a higher-ranked same-named movie',
    () async {
      final url = await service.bannerFor(_animeItem());
      expect(url, 'https://image.tmdb.org/t/p/original/tv-poster.png');
    },
  );

  test('a TMDB network error is not cached as a genuine miss', () async {
    adapter.failImagesTimes = 1;
    final item = _animeItem();

    expect(await service.bannerFor(item), isNull);
    expect(await service.bannerFor(item), isNotNull);
  });
}
