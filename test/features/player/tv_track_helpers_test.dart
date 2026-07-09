import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/hls.dart';
import 'package:watch_app/core/playback/tv_track_helpers.dart';

void main() {
  group('tvEpisodeUrl', () {
    test('rewrites sub<->dub', () {
      expect(tvEpisodeUrl('https://x/anime/sub/1', 'dub'), 'https://x/anime/dub/1');
      expect(tvEpisodeUrl('https://x/anime/dub/1', 'sub'), 'https://x/anime/sub/1');
    });
    test('no marker is a no-op', () {
      expect(tvEpisodeUrl('https://x/anime/ep1', 'dub'), 'https://x/anime/ep1');
    });
  });

  group('subtitleMime', () {
    test('by format', () {
      expect(subtitleMime('vtt'), 'text/vtt');
      expect(subtitleMime('ass'), 'text/x-ssa');
      expect(subtitleMime('srt'), 'application/x-subrip');
    });
    test('sniffs url when format missing', () {
      expect(subtitleMime(null, url: 'https://x/a.vtt'), 'text/vtt');
      expect(subtitleMime('', url: 'https://x/a.srt?y=1'), 'application/x-subrip');
    });
  });

  group('qualityHeight', () {
    test('parses labels', () {
      expect(qualityHeight('1080p'), 1080);
      expect(qualityHeight('720p'), 720);
      expect(qualityHeight('4K'), 2160);
      expect(qualityHeight('2160p'), 2160);
      expect(qualityHeight('auto'), 0);
    });
  });

  group('decideDefaultQuality', () {
    final v = [
      HlsVariant(quality: '2160p', url: 'a', bandwidth: 3),
      HlsVariant(quality: '1080p', url: 'b', bandwidth: 2),
      HlsVariant(quality: '480p', url: 'c', bandwidth: 1),
    ];
    test('auto/empty -> null', () {
      expect(decideDefaultQuality(variants: v, pref: 'auto'), isNull);
      expect(decideDefaultQuality(variants: v, pref: ''), isNull);
    });
    test('highest -> first', () {
      expect(decideDefaultQuality(variants: v, pref: 'highest')!.quality, '2160p');
    });
    test('exact match', () {
      expect(decideDefaultQuality(variants: v, pref: '1080p')!.quality, '1080p');
    });
    test('nearest-higher when exact absent', () {
      // want 720 -> smallest >= 720 is 1080p
      expect(decideDefaultQuality(variants: v, pref: '720p')!.quality, '1080p');
    });
    test('highest-below when nothing at/above', () {
      final low = [HlsVariant(quality: '480p', url: 'c', bandwidth: 1)];
      expect(decideDefaultQuality(variants: low, pref: '1080p')!.quality, '480p');
    });
    test('empty -> null', () {
      expect(decideDefaultQuality(variants: const [], pref: 'highest'), isNull);
    });
  });

  group('decideSubtitle', () {
    const en = TvTrack(id: '1:0', language: 'en', label: 'English');
    const ja = TvTrack(id: '2:0', language: 'jpn', label: 'Japanese');
    test('off / auto', () {
      expect(decideSubtitle(textTracks: const [en], pref: 'off').action, TvSubAction.off);
      expect(decideSubtitle(textTracks: const [en], pref: '').action, TvSubAction.auto);
    });
    test('selects matching text track', () {
      final d = decideSubtitle(textTracks: const [ja, en], pref: 'en');
      expect(d.action, TvSubAction.select);
      expect(d.track!.id, '1:0');
    });
    test('download when no track matches', () {
      final d = decideSubtitle(textTracks: const [ja], pref: 'en');
      expect(d.action, TvSubAction.download);
      expect(d.language!.iso1, 'en');
    });
    test('unknown pref -> auto', () {
      expect(decideSubtitle(textTracks: const [en], pref: 'zz').action, TvSubAction.auto);
    });
  });

  group('subtitleFontAsset', () {
    test('maps known families, null otherwise', () {
      expect(subtitleFontAsset('Inter'), 'assets/fonts/Inter.ttf');
      expect(subtitleFontAsset('Noto Sans'), 'assets/fonts/NotoSans-Regular.ttf');
      expect(subtitleFontAsset(''), isNull);
      expect(subtitleFontAsset('Comic Sans'), isNull);
    });
  });

  group('parseSubtitleColor', () {
    test('RRGGBBAA -> ARGB', () {
      expect(parseSubtitleColor('#FFFFFFFF'), 0xFFFFFFFF);
      expect(parseSubtitleColor('FF0000FF'), 0xFFFF0000); // red, opaque
    });
    test('RRGGBB gets opaque alpha', () {
      expect(parseSubtitleColor('#00FF00'), 0xFF00FF00);
    });
    test('garbage -> opaque white', () {
      expect(parseSubtitleColor('nope'), 0xFFFFFFFF);
    });
  });

  group('captionStyleFromPrefs', () {
    test('maps prefs to style', () {
      final s = captionStyleFromPrefs(
        scale: 1.3, colorHex: '#FFFFFFFF', bgOpacity: 0.0, position: 95, font: 'Inter');
      expect(s.scale, 1.3);
      expect(s.fgColor, 0xFFFFFFFF);
      expect(s.bgColor, 0); // transparent (opacity 0)
      expect(s.edge, isTrue); // outline when no bg box
      expect(s.position, closeTo(0.05, 0.001)); // (100-95)/100
      expect(s.fontFamily, 'Inter');
    });
    test('background opacity produces alpha-black bg and no edge', () {
      final s = captionStyleFromPrefs(
        scale: 1.0, colorHex: '#FFFFFFFF', bgOpacity: 1.0, position: 50, font: '');
      expect(s.bgColor, 0xFF000000);
      expect(s.edge, isFalse);
      expect(s.position, closeTo(0.5, 0.001));
    });
  });
}
