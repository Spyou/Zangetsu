import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_extension_service.dart';

void main() {
  test('rewrites a github raw apk URL to the jsDelivr CDN mirror', () {
    expect(
      jsdelivrMirror(
        'https://raw.githubusercontent.com/salmanbappi/extensions-repo/main/apk/aniyomi-all.agnisys-v16.11012.apk',
      ),
      'https://cdn.jsdelivr.net/gh/salmanbappi/extensions-repo@main/apk/aniyomi-all.agnisys-v16.11012.apk',
    );
  });

  test('handles nested paths and branch refs', () {
    expect(
      jsdelivrMirror(
        'https://raw.githubusercontent.com/o/r/v2/sub/dir/ext.apk',
      ),
      'https://cdn.jsdelivr.net/gh/o/r@v2/sub/dir/ext.apk',
    );
  });

  test('returns null for non-github-raw hosts', () {
    expect(jsdelivrMirror('https://example.com/apk/ext.apk'), isNull);
    expect(jsdelivrMirror('https://github.com/o/r/releases/x.apk'), isNull);
    expect(jsdelivrMirror('not a url at all ::::'), isNull);
  });

  test('returns null when the path is too short to be a raw file', () {
    expect(jsdelivrMirror('https://raw.githubusercontent.com/o/r'), isNull);
  });

  group('githubMirrors', () {
    test('returns jsDelivr + gh-proxy + statically for a raw URL', () {
      const url =
          'https://raw.githubusercontent.com/salmanbappi/extensions-repo/main/apk/x.apk';
      expect(githubMirrors(url), [
        'https://cdn.jsdelivr.net/gh/salmanbappi/extensions-repo@main/apk/x.apk',
        'https://gh-proxy.com/$url',
        'https://cdn.statically.io/gh/salmanbappi/extensions-repo/main/apk/x.apk',
      ]);
    });

    test('is empty for non-github-raw hosts', () {
      expect(githubMirrors('https://example.com/apk/ext.apk'), isEmpty);
      expect(githubMirrors('https://raw.githubusercontent.com/o/r'), isEmpty);
    });
  });
}
