import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/filler_service.dart';

void main() {
  test(
    'requests Tenrai filler pages once and caches the complete result',
    () async {
      final dio = Dio();
      addTearDown(dio.close);
      final requests = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final page = request.queryParameters['page'];
            handler.resolve(
              Response(
                requestOptions: request,
                data: {
                  'data': [
                    {'mal_id': page == 1 ? 57 : 271, 'filler': true},
                    {'mal_id': 1, 'filler': false},
                  ],
                  'pagination': {'last_visible_page': 2},
                },
              ),
            );
          },
        ),
      );
      final service = FillerService.withClient(dio);

      final first = service.fillerEpisodes(1735);
      expect(service.fillerEpisodes(1735), same(first));
      expect(await first, {57, 271});
      expect(service.peekCache(1735), {57, 271});
      expect(await service.fillerEpisodes(1735), {57, 271});
      expect(requests.map((request) => request.queryParameters['page']), [
        1,
        2,
      ]);
      for (final request in requests) {
        expect(request.uri.host, 'api.tenrai.org');
        expect(request.uri.path, '/v1/anime/1735/episodes');
        expect(request.queryParameters['filler'], true);
      }
    },
  );

  test('a failed request is retried on the next lookup', () async {
    final dio = Dio();
    addTearDown(dio.close);
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (++requests == 1) {
            handler.reject(DioException(requestOptions: request));
            return;
          }
          handler.resolve(
            Response(
              requestOptions: request,
              data: {
                'data': [
                  {'mal_id': 97, 'filler': true},
                ],
                'pagination': {'last_visible_page': 1},
              },
            ),
          );
        },
      ),
    );
    final service = FillerService.withClient(dio);

    expect(await service.fillerEpisodes(20), isEmpty);
    expect(service.peekCache(20), isNull);
    expect(await service.fillerEpisodes(20), {97});
    expect(requests, 2);
  });
}
