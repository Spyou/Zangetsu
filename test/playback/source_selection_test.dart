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
}
