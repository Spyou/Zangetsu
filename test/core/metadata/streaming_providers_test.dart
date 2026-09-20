import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/metadata/streaming_providers.dart';

/// One fake TMDB transport. Records the calls so the test can assert the region
/// actually reached the wire — a provider list for the wrong country is the
/// failure mode that looks fine and shows titles nobody can watch.
class _FakeGet {
  _FakeGet(this.responses);
  final Map<String, Map<String, dynamic>> responses;
  final calls = <(String, Map<String, dynamic>)>[];
  int hits = 0;

  Future<Map<String, dynamic>?> call(
    String path,
    Map<String, dynamic> params,
  ) async {
    hits++;
    calls.add((path, params));
    return responses[path];
  }
}

Map<String, dynamic> _row(int id, String name, String? logo, int priority) => {
  'provider_id': id,
  'provider_name': name,
  'logo_path': logo,
  'display_priority': priority,
};

void main() {
  test('merges movie and tv providers, deduped by id, priority order', () async {
    final fake = _FakeGet({
      '/watch/providers/tv': {
        'results': [
          _row(8, 'Netflix', '/n.png', 0),
          _row(283, 'Crunchyroll', '/c.png', 12),
        ],
      },
      '/watch/providers/movie': {
        'results': [
          _row(8, 'Netflix', '/n.png', 0), // duplicate across both endpoints
          _row(119, 'Amazon Prime Video', '/a.png', 3),
        ],
      },
    });
    final svc = StreamingProvidersService(fake.call);

    final list = await svc.list('IN');

    expect(list.map((s) => s.id).toList(), [8, 119, 283]);
    expect(list.first.name, 'Netflix');
    expect(list.first.logoUrl, 'https://image.tmdb.org/t/p/original/n.png');
  });

  // TMDB's own order in India puts FilmBox+, Cultpix and DOCSVILLE ahead of
  // Crunchyroll. The rail shows the first handful, so the majors have to lead.
  test('the big services lead, whatever priority TMDB gave them', () async {
    final fake = _FakeGet({
      '/watch/providers/tv': {
        'results': [
          _row(701, 'FilmBox+', '/f.png', 1),
          _row(692, 'Cultpix', '/c.png', 2),
          _row(283, 'Crunchyroll', '/cr.png', 40),
          _row(8, 'Netflix', '/n.png', 30),
          _row(119, 'Amazon Prime Video', '/a.png', 35),
        ],
      },
    });

    final list = await StreamingProvidersService(fake.call).list('IN');

    expect(list.map((s) => s.name).take(3).toList(), [
      'Netflix',
      'Amazon Prime Video',
      'Crunchyroll',
    ]);
    expect(list.map((s) => s.name).toList().sublist(3), [
      'FilmBox+',
      'Cultpix',
    ], reason: 'the rest keep TMDB order behind the majors');
  });

  test('two services outside the list keep TMDB order between them', () async {
    final fake = _FakeGet({
      '/watch/providers/tv': {
        'results': [
          _row(692, 'Cultpix', '/c.png', 9),
          _row(701, 'FilmBox+', '/f.png', 2),
        ],
      },
    });
    final list = await StreamingProvidersService(fake.call).list('IN');
    expect(list.map((s) => s.name).toList(), ['FilmBox+', 'Cultpix']);
  });

  // TMDB's list is mostly resellers: 38 of 92 entries in India, 163 of 333 in
  // the US. The Apple TV Store is the one that showed: its icon is nearly the
  // Apple TV icon, so the rail looked like it listed Apple twice.
  test('resellers, stores and ad-variants are dropped', () async {
    final fake = _FakeGet({
      '/watch/providers/tv': {
        'results': [
          _row(8, 'Netflix', '/n.png', 0),
          _row(350, 'Apple TV', '/at.png', 1),
          _row(2, 'Apple TV Store', '/as.png', 2),
          _row(2243, 'Apple TV Amazon Channel', '/ac.png', 3),
          _row(1968, 'Crunchyroll Amazon Channel', '/cc.png', 4),
          _row(2100, 'Amazon Prime Video with Ads', '/aa.png', 5),
          _row(175, 'Netflix Kids', '/nk.png', 6),
          _row(2285, 'JustWatch TV', '/jw.png', 7),
          _row(10, 'Amazon Video', '/av.png', 8),
          _row(283, 'Crunchyroll', '/cr.png', 9),
        ],
      },
    });

    final list = await StreamingProvidersService(fake.call).list('IN');

    expect(list.map((s) => s.name).toList(), [
      'Netflix',
      'Apple TV',
      'Crunchyroll',
    ]);
  });

  test('a real service whose name merely contains a blocked word survives',
      () async {
    final fake = _FakeGet({
      '/watch/providers/tv': {
        'results': [
          _row(9001, 'Channel 4', '/c4.png', 1),
          _row(9002, 'Discovery Kids Plus', '/dk.png', 2),
          _row(9003, 'The Store Next Door TV', '/sn.png', 3),
        ],
      },
    });
    final list = await StreamingProvidersService(fake.call).list('GB');
    expect(list.map((s) => s.name).toList(), [
      'Channel 4',
      'Discovery Kids Plus',
      'The Store Next Door TV',
    ], reason: 'the rules match the END of a name, not any occurrence');
  });

  test('sends the region to both endpoints', () async {
    final fake = _FakeGet({});
    await StreamingProvidersService(fake.call).list('IN');
    expect(fake.calls.length, 2);
    for (final (_, params) in fake.calls) {
      expect(params['watch_region'], 'IN');
    }
  });

  test('caches per region — a second call for the same region does not refetch',
      () async {
    final fake = _FakeGet({
      '/watch/providers/tv': {
        'results': [_row(8, 'Netflix', '/n.png', 0)],
      },
    });
    final svc = StreamingProvidersService(fake.call);
    await svc.list('IN');
    await svc.list('IN');
    expect(fake.hits, 2, reason: 'two endpoints, once — not four');

    await svc.list('US');
    expect(fake.hits, 4, reason: 'a different region is a different list');
  });

  // A blank grid that never retries is worse than a slow one: a single failed
  // call on a flaky connection would leave "no services" on screen until the
  // app restarts.
  test('an empty answer is not cached — the next call retries', () async {
    var empty = true;
    var hits = 0;
    Future<Map<String, dynamic>?> get(String path, Map<String, dynamic> _) async {
      hits++;
      if (empty) return {'results': <dynamic>[]};
      return path == '/watch/providers/tv'
          ? {
              'results': [_row(8, 'Netflix', '/n.png', 0)],
            }
          : null;
    }

    final svc = StreamingProvidersService(get);
    expect(await svc.list('IN'), isEmpty);
    expect(hits, 2);

    empty = false;
    expect((await svc.list('IN')).single.name, 'Netflix');
    expect(hits, 4, reason: 'it asked again rather than serving the empty one');
  });

  test('a row missing its id or name is skipped, not rendered blank', () async {
    final fake = _FakeGet({
      '/watch/providers/tv': {
        'results': [
          {'provider_name': 'No Id', 'display_priority': 1},
          {'provider_id': 9, 'display_priority': 1},
          _row(8, 'Netflix', null, 0),
        ],
      },
    });
    final list = await StreamingProvidersService(fake.call).list('IN');
    expect(list.map((s) => s.id).toList(), [8]);
    expect(list.single.logoUrl, isNull, reason: 'no logo path, no url');
  });

  test('a failed fetch is an empty list, never a throw', () async {
    Future<Map<String, dynamic>?> boom(String _, Map<String, dynamic> _) async {
      throw StateError('network down');
    }

    expect(await StreamingProvidersService(boom).list('IN'), isEmpty);
  });

}
