import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/share/local_video_link.dart';

// "Open with" support puts a new check at the FRONT of OpenLinkService._onLink,
// ahead of the tracker-OAuth and share-link handlers that have always been
// there. The risk isn't that it fails to match a video — it's that it matches
// something it shouldn't and silently eats a link another handler owns.

void main() {
  group('matches local video', () {
    test('a file:// video', () {
      expect(LocalVideoLink.matches(Uri.parse('file:///sdcard/a.mkv')), isTrue);
      expect(LocalVideoLink.matches(Uri.parse('file:///sdcard/a.mp4')), isTrue);
    });

    test('a content:// URI (the filter already vouched for its mime type)', () {
      expect(
        LocalVideoLink.matches(Uri.parse('content://media/external/video/42')),
        isTrue,
      );
    });

    test('case does not matter', () {
      expect(LocalVideoLink.matches(Uri.parse('file:///x/A.MKV')), isTrue);
    });
  });

  group('never steals another handler link', () {
    test('tracker OAuth redirects', () {
      for (final host in ['anilist-auth', 'mal-auth', 'simkl-auth']) {
        expect(
          LocalVideoLink.matches(Uri.parse('zangetsu://$host?code=abc')),
          isFalse,
          reason: '$host must still reach its tracker service',
        );
      }
    });

    test('share and pairing deep links', () {
      for (final u in [
        'zangetsu://open?d=x&t=y',
        'zangetsu://pair?code=1234',
        'zangetsu://room?code=1234',
        'https://zangetsu.online/pair/?code=1234',
      ]) {
        expect(LocalVideoLink.matches(Uri.parse(u)), isFalse, reason: u);
      }
    });

    test('web video links are not claimed — the manifest does not ask for '
        'http/https, and neither does this', () {
      expect(
        LocalVideoLink.matches(Uri.parse('https://cdn.example.com/a.mp4')),
        isFalse,
      );
      expect(
        LocalVideoLink.matches(Uri.parse('http://example.com/s.m3u8')),
        isFalse,
      );
    });

    test('a non-video file is not claimed', () {
      expect(LocalVideoLink.matches(Uri.parse('file:///x/notes.pdf')), isFalse);
      expect(LocalVideoLink.matches(Uri.parse('file:///x/song.mp3')), isFalse);
    });
  });

  group('title', () {
    test('is the file name', () {
      expect(
        LocalVideoLink.titleFor(Uri.parse('file:///sdcard/Movies/Dune.mkv')),
        'Dune.mkv',
      );
    });

    test('decodes percent-escapes', () {
      expect(
        LocalVideoLink.titleFor(Uri.parse('file:///x/My%20Show%20E01.mp4')),
        'My Show E01.mp4',
      );
    });

    test('falls back rather than showing an empty bar', () {
      expect(LocalVideoLink.titleFor(Uri.parse('content://a/')), 'Video');
    });
  });
}
