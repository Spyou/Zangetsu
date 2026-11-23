import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/player/tv_progressive_sources.dart';

void main() {
  const first = VideoSource(url: 'https://example.com/first', quality: '720p');
  const later = VideoSource(url: 'https://example.com/later', quality: '1080p');

  test(
    'starts with the first result and keeps later sources for the picker',
    () async {
      final events = StreamController<List<VideoSource>>();
      var calls = 0;
      final lookup = TvProgressiveSources((url, category) {
        calls++;
        expect(url, 'zm://anime/mal:1/ep/1');
        expect(category, 'sub');
        return events.stream;
      });

      final opening = lookup.first('zm://anime/mal:1/ep/1', 'sub');
      events.add(const [first]);
      expect(await opening, const [first]);

      events.add(const [first, later]);
      await Future<void>.delayed(Duration.zero);
      expect(await lookup.latest('zm://anime/mal:1/ep/1', 'sub'), const [
        first,
        later,
      ]);
      expect(calls, 1);

      await lookup.dispose();
      await events.close();
    },
  );

  test('keeps sub and dub resolution separate', () async {
    final lookup = TvProgressiveSources((url, category) {
      return Stream.value(category == 'sub' ? const [first] : const [later]);
    });

    expect(await lookup.first('zm://anime/mal:1/ep/1', 'sub'), const [first]);
    expect(await lookup.first('zm://anime/mal:1/ep/1', 'dub'), const [later]);
    await lookup.dispose();
  });

  test('late mirror metadata replaces the same URL in the picker', () async {
    const enriched = VideoSource(
      url: 'https://example.com/first',
      quality: '720p',
      subtitles: [Subtitle(url: 'https://example.com/hi.vtt', lang: 'hi')],
    );
    final lookup = TvProgressiveSources(
      (url, category) => Stream.value(const [first]),
      poll: (url, category) async => const [enriched],
    );

    expect(await lookup.first('zm://anime/mal:1/ep/1', 'sub'), const [first]);
    expect(await lookup.latest('zm://anime/mal:1/ep/1', 'sub'), const [
      enriched,
    ]);
    await lookup.dispose();
  });

  test(
    'the source picker also includes late mirrors of the winning source',
    () async {
      var polls = 0;
      final lookup = TvProgressiveSources(
        (url, category) => Stream.value(const [first]),
        poll: (url, category) async =>
            ++polls == 1 ? const [first, later] : const <VideoSource>[],
      );

      expect(await lookup.first('zm://anime/mal:1/ep/1', 'sub'), const [first]);
      expect(await lookup.latest('zm://anime/mal:1/ep/1', 'sub'), const [
        first,
        later,
      ]);
      expect(await lookup.latest('zm://anime/mal:1/ep/1', 'sub'), const [
        first,
        later,
      ]);
      await lookup.dispose();
    },
  );

  test('prefetch reuses a successful result for the next episode', () async {
    var calls = 0;
    final lookup = TvProgressiveSources((url, category) {
      calls++;
      return Stream.value(const [first]);
    });
    await lookup.prefetch('episode-2', 'dub');
    await lookup.prefetch('episode-2', 'dub');
    expect(await lookup.first('episode-2', 'dub'), [first]);
    expect(calls, 1);
    await lookup.dispose();
  });

  test(
    'failed prefetch leaves explicit episode playback able to retry',
    () async {
      var calls = 0;
      final lookup = TvProgressiveSources((url, category) {
        return ++calls == 1
            ? Stream.error(StateError('offline'))
            : Stream.value(const [first]);
      });
      await lookup.prefetch('episode-2', 'sub');
      expect(await lookup.first('episode-2', 'sub'), [first]);
      expect(calls, 2);
      await lookup.dispose();
    },
  );

  test('an empty completed sweep does not hang playback', () async {
    final lookup = TvProgressiveSources(
      (url, category) => const Stream.empty(),
    );
    expect(await lookup.first('zm://anime/mal:1/ep/1', 'sub'), isEmpty);
    await lookup.dispose();
  });
}
