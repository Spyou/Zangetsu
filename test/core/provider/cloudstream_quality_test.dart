import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';

// CloudStream's `Qualities.Unknown` is the number 400, and its own UI renders
// that as blank. We used to pass any non-zero value straight through as
// "${n}p", so an extractor that couldn't read a resolution produced a "400p"
// no stream has — which then sorted as if it sat between 360p and 480p.
void main() {
  final cs = CloudStreamProvider(name: 'X', lang: 'en', types: const ['Movie']);

  List<String?> qualitiesFor(List<int> raw) => cs
      .sourcesFromResult({
        'sources': [
          for (final q in raw)
            {'url': 'https://x/$q.mp4', 'name': 'Server $q', 'quality': q},
        ],
        'subtitles': const [],
      })
      .map((s) => s.quality)
      .toList();

  test('Unknown (400) carries no quality rather than inventing 400p', () {
    expect(qualitiesFor([400]), [null]);
  });

  test('0 stays Auto and real resolutions pass through', () {
    expect(qualitiesFor([0, 720, 1080, 2160]), ['auto', '720p', '1080p', '2160p']);
  });

  test('the link itself survives having no quality', () {
    final out = cs.sourcesFromResult({
      'sources': [
        {'url': 'https://x/a.mp4', 'name': 'HubCloud', 'quality': 400},
      ],
      'subtitles': const [],
    });
    expect(out, hasLength(1));
    expect(out.single.url, 'https://x/a.mp4');
    expect(out.single.label, 'HubCloud');
  });
}
