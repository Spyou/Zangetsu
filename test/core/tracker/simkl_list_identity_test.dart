import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/tracker/tracker_item_url.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SimklService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('simkl-list-identity-');
    Hive.init(directory.path);
    final box = await Hive.openBox(SimklService.boxName);
    await box.putAll({'accessToken': 'test-token', 'viewerName': 'test'});
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'shows': [
                  {
                    'status': 'watching',
                    'show': {
                      'title': 'Series',
                      'ids': {'tmdb': 42},
                    },
                  },
                ],
                'movies': [
                  {
                    'status': 'plantowatch',
                    'movie': {
                      'title': 'Film',
                      'ids': {'tmdb': 42},
                    },
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    service = SimklService(dio);
  });

  tearDown(() async {
    service.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('Simkl list taps keep TV and movie identities separate', () async {
    final entries = await service.fetchList();
    expect(entries, hasLength(2));
    final show = entries.singleWhere((entry) => entry.item.title == 'Series');
    final movie = entries.singleWhere((entry) => entry.item.title == 'Film');
    expect(
      playableTrackerItem(show.item, savedFrom: 'Simkl')!.url,
      'zm://tv/tmdb:42',
    );
    expect(
      playableTrackerItem(movie.item, savedFrom: 'Simkl')!.url,
      'zm://movie/tmdb:42',
    );
  });
}
