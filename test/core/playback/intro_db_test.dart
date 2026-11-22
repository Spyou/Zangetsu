import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/skip_service.dart';

void main() {
  late Dio dio;
  late SkipService service;
  late List<Uri> requests;

  setUp(() {
    requests = [];
    dio = Dio();
    addTearDown(dio.close);
    service = SkipService(dio);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options.uri);
          handler.resolve(
            Response(
              requestOptions: options,
              data: options.uri.path.endsWith('/external_ids')
                  ? {'imdb_id': 'tt0903747'}
                  : {
                      'intro': {'start_ms': 2500, 'end_ms': 58000},
                      'recap': {'start_ms': 0, 'end_ms': 2000},
                      'outro': {'start_ms': 50000, 'end_ms': 90000},
                    },
            ),
          );
        },
      ),
    );
  });

  test(
    'matches exact season and episode and discards out-of-range timings',
    () async {
      final skips = await service.introDbTimes(
        imdbId: null,
        tmdbId: 1396,
        isTv: true,
        season: 2,
        episode: 3,
        duration: const Duration(minutes: 1),
      );
      expect(requests.first.path, '/3/tv/1396/external_ids');
      expect(requests.last.queryParameters, {
        'imdb_id': 'tt0903747',
        'season': '2',
        'episode': '3',
      });
      expect(skips.map((s) => s.type), ['op', 'recap']);
    },
  );

  test('movie uses its IMDb ID without episode coordinates', () async {
    final skips = await service.introDbTimes(
      imdbId: 'tt0371746',
      tmdbId: null,
      isTv: false,
      season: null,
      episode: null,
      duration: const Duration(minutes: 2),
    );
    expect(requests.single.queryParameters, {
      'imdb_id': 'tt0371746',
      'is_movie': 'true',
    });
    expect(skips.map((s) => s.type), ['ed']);
  });

  test('unknown season never falls back to another episode', () async {
    final skips = await service.introDbTimes(
      imdbId: 'tt0903747',
      tmdbId: null,
      isTv: true,
      season: null,
      episode: 3,
      duration: const Duration(minutes: 1),
    );
    expect(skips, isEmpty);
    expect(requests, isEmpty);
  });
}
