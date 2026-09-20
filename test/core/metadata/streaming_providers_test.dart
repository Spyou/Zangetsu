import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/metadata/streaming_providers.dart';
import 'package:watch_app/core/metadata/streaming_service.dart';

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

  test('a pin round-trips through its stored string', () {
    const pin = StreamingPin(id: 8, name: 'Netflix');
    final back = StreamingPin.fromEntry(pin.toEntry());
    expect(back?.id, 8);
    expect(back?.name, 'Netflix');
    expect(StreamingPin.fromEntry('garbage'), isNull);
    expect(StreamingPin.fromEntry('x|Netflix'), isNull);
  });
}
