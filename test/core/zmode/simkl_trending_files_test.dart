// Simkl asked us off /movies/trending/week and friends: those count against
// the app's daily request limit, and we were burning it for the whole
// userbase every day. The pre-built files on data.simkl.in carry the same
// titles, don't count, and hand us the Simkl id outright — which is the other
// half of this, since we were spending a /search/id call re-asking for an id
// we'd already been given.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_config.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/environment.dart';
import 'package:watch_app/core/zmode/simkl_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

/// Records every URL asked for and answers from [respond].
class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond, {this.redirectTo});
  final Object? Function(Uri uri) respond;

  /// Location header for `/redirect`, when a test exercises that path.
  final String? redirectTo;
  final asked = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, __) async {
    asked.add(o.uri);
    if (o.uri.path == '/redirect') {
      return ResponseBody.fromString(
        '',
        301,
        headers: {
          'location': [redirectTo ?? '//simkl.com'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(respond(o.uri)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// One row as the data files actually shape it — both ids present.
Map<String, dynamic> _row(int tmdb, int simkl, String title) => {
  'title': title,
  'poster': 'aa/bb',
  'ids': {'simkl_id': simkl, 'tmdb': '$tmdb', 'imdb': 'tt$tmdb'},
  'ratings': {
    'simkl': {'rating': 7.5, 'votes': 10},
  },
};

void main() {
  setUp(SimklCatalogue.resetIdCache);

  group('home rows come from the cached files, not the API', () {
    test('every request goes to data.simkl.in', () async {
      final adapter = _Adapter((_) => [_row(1, 11, 'A'), _row(2, 22, 'B')]);
      final cat = SimklCatalogue(Dio()..httpClientAdapter = adapter);

      final sections = await cat.home();

      expect(sections, hasLength(4));
      expect(
        adapter.asked.map((u) => u.host).toSet(),
        {'data.simkl.in'},
        reason: 'a trending call that still hits api.simkl.com burns quota',
      );
      expect(
        adapter.asked.any((u) => u.path.contains('trending/week')),
        isFalse,
        reason: 'that is the old API shape, not the file path',
      );
    });

    test('a rail still shows 30, the same as before the files', () async {
      final cat = SimklCatalogue(
        Dio()
          ..httpClientAdapter = _Adapter(
            (_) => [for (var i = 0; i < 100; i++) _row(i, 100 + i, 'T$i')],
          ),
      );

      // The file carries 100. The rail is not the place for them — See All is.
      expect((await cat.home()).first.items, hasLength(30));
    });

    test('the four files it reads are the ones Simkl publishes', () async {
      final adapter = _Adapter((_) => [_row(1, 11, 'A')]);
      await SimklCatalogue(Dio()..httpClientAdapter = adapter).home();

      expect(adapter.asked.map((u) => u.path).toSet(), {
        '/discover/trending/movies/week_100.json',
        '/discover/trending/tv/week_100.json',
        '/discover/trending/movies/month_100.json',
        '/discover/trending/tv/month_100.json',
      });
    });

    test('a file is fetched once, not once per Home build', () async {
      final adapter = _Adapter((_) => [_row(1, 11, 'A')]);
      final cat = SimklCatalogue(Dio()..httpClientAdapter = adapter);

      await cat.home();
      final afterFirst = adapter.asked.length;
      await cat.home();

      // ~300 KB a file: re-downloading four of them on every Home build is a
      // megabyte of somebody's mobile data per refresh.
      expect(adapter.asked.length, afterFirst);
    });
  });

  group('browsing a row pages through the file', () {
    test('See All reads the deep file, not the one Home uses', () async {
      // 100 is a ceiling where there wasn't one before. Someone who opened
      // the row came to scroll, so pay the bigger download once, there.
      final adapter = _Adapter((_) => [_row(1, 11, 'A')]);
      await SimklCatalogue(
        Dio()..httpClientAdapter = adapter,
      ).browseRow('movies/week_100', 1);

      expect(adapter.asked.single.path, contains('week_500'));
    });

    test('page 2 slices locally instead of asking again', () async {
      final adapter = _Adapter(
        (_) => [for (var i = 0; i < 100; i++) _row(1000 + i, 2000 + i, 'T$i')],
      );
      final cat = SimklCatalogue(Dio()..httpClientAdapter = adapter);

      final first = await cat.browseRow('movies/week_100', 1);
      final asked = adapter.asked.length;
      final second = await cat.browseRow('movies/week_100', 2);

      expect(first, hasLength(30));
      expect(second, hasLength(30));
      expect(first.first.id, isNot(second.first.id));
      expect(adapter.asked.length, asked, reason: 'page 2 was a second fetch');
    });

    test('running off the end stops the grid', () async {
      final cat = SimklCatalogue(
        Dio()
          ..httpClientAdapter = _Adapter(
            (_) => [for (var i = 0; i < 40; i++) _row(i, 100 + i, 'T$i')],
          ),
      );

      expect(await cat.browseRow('tv/week_100', 2), hasLength(10));
      expect(await cat.browseRow('tv/week_100', 3), isEmpty);
    });
  });

  group('the Simkl id rides along instead of being looked up', () {
    test('opening a title from a row needs no lookup at all', () async {
      final adapter = _Adapter((uri) {
        if (uri.host == 'data.simkl.in') return [_row(550, 9911, 'Fight Club')];
        return {'title': 'Fight Club'};
      });
      final cat = SimklCatalogue(Dio()..httpClientAdapter = adapter);

      await cat.home();
      adapter.asked.clear();
      await cat.detail(const ZCanonical(ZKind.movie, 'tmdb:550'));

      expect(
        adapter.asked.any((u) => u.path == '/redirect'),
        isFalse,
        reason: 'the row already handed us this id',
      );
      expect(adapter.asked.single.path, '/movies/9911');
    });

    test('a title we have never seen falls back to the redirect', () async {
      final adapter = _Adapter(
        (_) => {'title': 'From a library'},
        redirectTo: '//simkl.com/movies/4242/from-a-library',
      );
      final cat = SimklCatalogue(Dio()..httpClientAdapter = adapter);

      // Cold: nothing fetched this session, e.g. opened from My List.
      final d = await cat.detail(const ZCanonical(ZKind.movie, 'tmdb:987654'));

      expect(d.title, 'From a library');
      expect(adapter.asked.first.path, '/redirect');
    });
  });

  test('a title the user already tracks needs no lookup at all', () {
    // Their synced list carries both ids for every entry, and a title someone
    // tracks is the one they're most likely to open. SimklService feeds these
    // in as it parses the list — this is the seam it writes through.
    SimklCatalogue.rememberSimklId(27205, 472214);

    expect(
      SimklCatalogue.simklIdFor(
        Dio()..httpClientAdapter = _Adapter((_) => throw StateError('asked!')),
        27205,
        isTv: false,
      ),
      completion(472214),
    );
  });

  group('the params Simkl requires on every request', () {
    RequestOptions optionsFor(String url) {
      final o = RequestOptions(path: url);
      applySimklConventions(o);
      return o;
    }

    test('the API host gets all three plus a User-Agent', () {
      final o = optionsFor('https://api.simkl.com/movies/550');

      expect(o.queryParameters['client_id'], Environment.simklClientId);
      expect(o.queryParameters['app-name'], Environment.simklAppName);
      expect(o.queryParameters['app-version'], kAppVersion);
      expect(o.headers['User-Agent'], '$kAppName/$kAppVersion');
    });

    test('the data-file host gets them too', () {
      // Simkl says to send these even where no api key is needed — it is how
      // they see us in their log at all.
      final o = optionsFor(
        'https://data.simkl.in/discover/trending/movies/week_100.json',
      );

      expect(o.queryParameters['client_id'], Environment.simklClientId);
      expect(o.headers['User-Agent'], isNotNull);
    });

    test('everything else is left alone', () {
      final o = optionsFor('https://api.themoviedb.org/3/movie/550');

      expect(o.queryParameters, isEmpty);
      expect(o.headers['User-Agent'], isNull);
    });
  });
}
