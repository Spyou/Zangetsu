import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_mapping.dart';
import 'package:watch_app/core/playback/source_selection.dart';
import 'package:watch_app/core/models/video_source.dart';

/// Aniyomi has no sub/dub parameter — `getVideoList(episode)` takes an episode
/// and nothing else. A source carrying both cuts says so in each video's OWN
/// title ("Dub - 1080p"), so both arrive in one list. That word used to be read
/// straight into `quality` as though it were a resolution, so a Dub row was
/// visible but nothing could switch to it: [VideoSource.kind] was never set.
void main() {
  _noToggleNarrowing();
  group('reading the cut out of a video title', () {
    test('a dub is recognised and the word leaves the quality label', () {
      final r = audioKindFromTitle('Dub - 1080p');
      expect(r.kind, AudioKind.dub);
      expect(r.quality, '1080p', reason: 'would read "DUB • Dub - 1080p"');
    });

    test('the marker is found wherever it sits', () {
      expect(audioKindFromTitle('1080p (Dub)').kind, AudioKind.dub);
      expect(audioKindFromTitle('1080p (Dub)').quality, '1080p');
      expect(audioKindFromTitle('Server A · Dubbed · 720p').kind, AudioKind.dub);
      expect(audioKindFromTitle('Server A · Dubbed · 720p').quality,
          'Server A · 720p');
    });

    test('sub, however it is spelled', () {
      for (final t in ['Sub - 720p', 'Subbed 720p', 'HardSub 720p', 'soft-sub 720p']) {
        expect(audioKindFromTitle(t).kind, AudioKind.sub, reason: t);
      }
      expect(audioKindFromTitle('Raw - 1080p').kind, AudioKind.raw);
    });

    test('a title that is only the cut leaves no quality behind', () {
      final r = audioKindFromTitle('Dub');
      expect(r.kind, AudioKind.dub);
      expect(r.quality, isNull, reason: 'an empty label is worse than none');
    });

    test('whole words only', () {
      // The failure this guards: "Subaru" is not a sub, "Dublin" is not a dub.
      for (final t in ['Subaru 1080p', 'Dublin Stream', 'Redub2 mirror']) {
        expect(audioKindFromTitle(t).kind, AudioKind.unknown, reason: t);
        expect(audioKindFromTitle(t).quality, t, reason: 'label untouched: $t');
      }
    });

    test('a plain quality says nothing about audio', () {
      for (final t in ['1080p', '720p', 'Doodstream', '', null]) {
        expect(audioKindFromTitle(t).kind, AudioKind.unknown, reason: '$t');
      }
      expect(audioKindFromTitle('1080p').quality, '1080p');
    });
  });

  group('what an unmarked entry is taken to be', () {
    test('nothing, when no title mentions a dub — the no-regression case', () {
      // THE contract. Every Aniyomi source that has only ever had one cut must
      // keep the exact `unknown` kind it had before, or its picker, ordering
      // and failover all change underneath it.
      expect(
        fallbackAudioKind(['1080p', '720p', 'Doodstream', null]),
        AudioKind.unknown,
      );
    });

    test('sub, once something in the list is marked dub', () {
      expect(
        fallbackAudioKind(['1080p', 'Dub - 1080p', '720p']),
        AudioKind.sub,
      );
    });

    test('a dub-only list still infers nothing for the rest', () {
      expect(fallbackAudioKind(['Dub - 1080p', 'Dub - 720p']), AudioKind.sub);
    });
  });

  group('videoSourceFromVideo', () {
    Map<String, dynamic> v(String title) => {
      'videoUrl': 'https://cdn.test/x.m3u8',
      'videoTitle': title,
    };

    test('carries the cut through, and keeps the resolution readable', () {
      final s = videoSourceFromVideo(v('Dub - 1080p'));
      expect(s.kind, AudioKind.dub);
      expect(s.quality, '1080p');
    });

    test('the fallback only fills an entry that named nothing', () {
      expect(
        videoSourceFromVideo(v('1080p'), fallbackKind: AudioKind.sub).kind,
        AudioKind.sub,
      );
      // An explicit dub is never overwritten by the fallback.
      expect(
        videoSourceFromVideo(v('Dub - 1080p'), fallbackKind: AudioKind.sub).kind,
        AudioKind.dub,
      );
    });

    test('default fallback leaves it unknown, as before', () {
      expect(videoSourceFromVideo(v('1080p')).kind, AudioKind.unknown);
    });
  });

  group('every server still reaches the picker', () {
    // The guarantee behind the change: setting `kind` GROUPS the list, it
    // never trims it. Both server sheets render
    //   for (final k in availableKinds(sources))
    //     for (final s in sourcesForKind(sources, k))
    // so this walk must always return the whole list, whatever kinds are in it.
    List<VideoSource> asRendered(List<VideoSource> sources) => [
      for (final k in availableKinds(sources)) ...sourcesForKind(sources, k),
    ];

    VideoSource src(String url, AudioKind k) =>
        VideoSource(url: url, kind: k, quality: '1080p');

    test('a mixed sub/dub list loses nothing', () {
      final all = [
        src('a', AudioKind.sub),
        src('b', AudioKind.dub),
        src('c', AudioKind.sub),
        src('d', AudioKind.dub),
      ];
      expect(asRendered(all).toSet(), all.toSet());
      expect(asRendered(all), hasLength(all.length));
    });

    test('an all-unknown list — the untouched-source case — loses nothing', () {
      final all = [
        src('a', AudioKind.unknown),
        src('b', AudioKind.unknown),
      ];
      expect(asRendered(all), all);
    });

    test('every combination of kinds survives the round trip', () {
      const kinds = AudioKind.values;
      for (var i = 0; i < kinds.length; i++) {
        for (var j = 0; j < kinds.length; j++) {
          for (var k = 0; k < kinds.length; k++) {
            final all = [
              src('a', kinds[i]),
              src('b', kinds[j]),
              src('c', kinds[k]),
            ];
            expect(
              asRendered(all).toSet(),
              all.toSet(),
              reason: '${kinds[i]}/${kinds[j]}/${kinds[k]}',
            );
          }
        }
      }
    });
  });

  group('picking a stream out of a mixed list', () {
    // Why switchCategory now passes `prefer`. These pin the selection rule it
    // depends on — that a mixed list really does hand back the wrong cut when
    // nobody says which one is wanted.
    final mixed = [
      const VideoSource(url: 'sub-1080', kind: AudioKind.sub, quality: '1080p'),
      const VideoSource(url: 'dub-1080', kind: AudioKind.dub, quality: '1080p'),
      const VideoSource(url: 'dub-720', kind: AudioKind.dub, quality: '720p'),
    ];

    test('asking for dub gets dub', () {
      expect(pickDefault(mixed, prefer: AudioKind.dub)!.url, 'dub-1080');
    });

    test('saying nothing gets sub — the bug switchCategory used to hit', () {
      // pickDefault defaults to sub, so a caller that forgets `prefer` while
      // switching TO dub is silently handed the sub stream.
      expect(pickDefault(mixed)!.url, 'sub-1080');
    });

    test('a single-cut list ignores prefer entirely — the no-regression case', () {
      // Every Aniyomi source that never mentions a dub stays `unknown`, so
      // neither kind matches and the whole pool is used, exactly as before.
      final unknownOnly = [
        const VideoSource(url: 'a', kind: AudioKind.unknown, quality: '1080p'),
        const VideoSource(url: 'b', kind: AudioKind.unknown, quality: '720p'),
      ];
      expect(pickDefault(unknownOnly, prefer: AudioKind.dub)!.url, 'a');
      expect(pickDefault(unknownOnly, prefer: AudioKind.sub)!.url, 'a');
      expect(pickDefault(unknownOnly)!.url, 'a');
    });
  });
}

/// A source that labels its cuts but offers no Sub/Dub toggle must not have its
/// default narrowed to one of them — 1.9.8 picked the best of the whole list,
/// and with no toggle there is no way back to the other cut.
void _noToggleNarrowing() {
  group('no toggle means no narrowing', () {
    final mixed = [
      const VideoSource(url: 'sub-480', quality: '480p', kind: AudioKind.sub),
      const VideoSource(url: 'dub-1080', quality: '1080p', kind: AudioKind.dub),
    ];

    test('the whole list is in play when nothing narrows it', () {
      // AudioKind.unknown matches neither, so pickDefault uses every server —
      // the 1080p dub wins on quality rather than losing for being a dub.
      final pick = pickDefault(mixed, prefer: AudioKind.unknown);
      expect(pick?.url, 'dub-1080');
    });

    test('asking for a cut still narrows to it, for sources that have a toggle',
        () {
      expect(pickDefault(mixed, prefer: AudioKind.sub)?.url, 'sub-480');
      expect(pickDefault(mixed, prefer: AudioKind.dub)?.url, 'dub-1080');
    });

    test('an unlabelled list is unaffected either way', () {
      final plain = [
        const VideoSource(url: 'a', quality: '720p'),
        const VideoSource(url: 'b', quality: '1080p'),
      ];
      expect(pickDefault(plain, prefer: AudioKind.unknown)?.url, 'b');
      expect(pickDefault(plain, prefer: AudioKind.sub)?.url, 'b');
    });
  });
}
