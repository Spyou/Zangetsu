import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_selection.dart';

VideoSource _s(String q, AudioKind k) =>
    VideoSource(url: 'https://x/$q', quality: q, container: SourceContainer.hls, kind: k);

void main() {
  test('sortByQuality orders high→low, unknown last', () {
    final out = sortByQuality([_s('480p', AudioKind.sub), _s('1080p', AudioKind.sub),
      _s('', AudioKind.sub), _s('720p', AudioKind.sub)]);
    expect(out.map((s) => s.quality).toList(), ['1080p', '720p', '480p', '']);
  });

  test('availableKinds lists distinct kinds present', () {
    final kinds = availableKinds([_s('720p', AudioKind.sub), _s('720p', AudioKind.dub),
      _s('480p', AudioKind.sub)]);
    expect(kinds.contains(AudioKind.sub), true);
    expect(kinds.contains(AudioKind.dub), true);
    expect(kinds.length, 2);
  });

  test('pickDefault prefers requested kind at highest quality', () {
    final all = [_s('480p', AudioKind.sub), _s('1080p', AudioKind.dub), _s('1080p', AudioKind.sub)];
    final picked = pickDefault(all, prefer: AudioKind.sub);
    expect(picked!.kind, AudioKind.sub);
    expect(picked.quality, '1080p');
  });

  test('pickDefault falls back to any kind when preferred absent', () {
    final all = [_s('720p', AudioKind.dub)];
    expect(pickDefault(all, prefer: AudioKind.sub)!.kind, AudioKind.dub);
  });

  test('sourcesForKind filters', () {
    final all = [_s('720p', AudioKind.sub), _s('720p', AudioKind.dub)];
    expect(sourcesForKind(all, AudioKind.dub).single.kind, AudioKind.dub);
  });

  // A resolution preference has to pick the STARTING source, because for a
  // provider that ships one file per quality there is nothing to switch once
  // playback has begun — swapping then would change server, audio and subs.
  group('pickDefault preferQuality', () {
    final all = [
      _s('2160p', AudioKind.sub),
      _s('1080p', AudioKind.sub),
      _s('480p', AudioKind.sub),
    ];

    test('starts on the source matching the preference', () {
      expect(pickDefault(all, preferQuality: '1080p')!.quality, '1080p');
      expect(pickDefault(all, preferQuality: '480p')!.quality, '480p');
    });

    test('nearest when the exact resolution is absent, higher on a tie', () {
      final gap = [_s('2160p', AudioKind.sub), _s('480p', AudioKind.sub)];
      expect(pickDefault(gap, preferQuality: '720p')!.quality, '480p');
      // 1080 is equidistant from 720 and 1440 -> the higher one wins.
      final tie = [_s('1440p', AudioKind.sub), _s('720p', AudioKind.sub)];
      expect(pickDefault(tie, preferQuality: '1080p')!.quality, '1440p');
    });

    test('auto/highest/null keep the existing highest-first default', () {
      expect(pickDefault(all, preferQuality: 'auto')!.quality, '2160p');
      expect(pickDefault(all, preferQuality: 'highest')!.quality, '2160p');
      expect(pickDefault(all)!.quality, '2160p');
    });

    test('preference never escapes the requested audio kind', () {
      final mixed = [_s('1080p', AudioKind.dub), _s('480p', AudioKind.sub)];
      final picked = pickDefault(mixed, prefer: AudioKind.sub, preferQuality: '1080p');
      expect(picked!.kind, AudioKind.sub);
      expect(picked.quality, '480p');
    });

    test('sources carrying no resolution fall back, never crash', () {
      final none = [_s('', AudioKind.sub), _s('auto', AudioKind.sub)];
      expect(pickDefault(none, preferQuality: '1080p'), isNotNull);
      expect(pickDefault([], preferQuality: '1080p'), isNull);
    });
  });

  group('resolutionPx', () {
    test('reads real resolutions and the usual shorthand', () {
      expect(resolutionPx('1080p'), 1080);
      expect(resolutionPx('4K'), 2160);
      expect(resolutionPx('FHD'), 1080);
    });

    test('names that state no resolution give null', () {
      expect(resolutionPx(null), isNull);
      expect(resolutionPx('auto'), isNull);
      expect(resolutionPx('highest'), isNull);
      expect(resolutionPx('Doodstream'), isNull);
    });
  });
}
