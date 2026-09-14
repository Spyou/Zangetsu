import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

/// Both fixtures are real responses, captured 2026-09-14.
///
/// The bug: `server: cloudflare` alone counted as a challenge, so every
/// ordinary Cloudflare 403 latched the source as "needs a solve" — the
/// resolver then skipped it and offered a button that could never work.
void main() {
  group('a plain Cloudflare 403 is not a challenge', () {
    test('the stream CDN that took AniKoto out of every sweep', () {
      // fetch.nexabloom.top — 403, server: cloudflare, cf-ray present, and no
      // challenge anywhere in the body. A hotlink block, not an interstitial.
      expect(
        looksLikeCfChallenge(
          status: 403,
          cfMitigated: null,
          body: '<!DOCTYPE html><html class="no-js" lang="en-US">'
              '<head><title>Access denied</title></head>'
              '<body><h1>Error 1010</h1></body></html>',
        ),
        isFalse,
      );
    });

    test('Cloudflare fronting a site says nothing on its own', () {
      expect(
        looksLikeCfChallenge(status: 403, body: 'forbidden'),
        isFalse,
      );
    });
  });

  group('a real challenge is still caught', () {
    test('cf-mitigated names it, as on the live AnimePahe domain', () {
      // animepahe.pw — 403 + cf-mitigated: challenge.
      expect(
        looksLikeCfChallenge(
          status: 403,
          cfMitigated: 'challenge',
          body: '',
        ),
        isTrue,
      );
    });

    test('the interstitial markup, with no header to go on', () {
      for (final marker in [
        'Just a moment...',
        '<div id="challenge-platform">',
        'cf-chl-bypass',
        'Checking your browser before accessing',
        'Enable JavaScript and cookies to continue',
      ]) {
        expect(
          looksLikeCfChallenge(status: 503, body: marker),
          isTrue,
          reason: 'missed: $marker',
        );
      }
    });
  });

  test('only 403 and 503 are ever considered', () {
    for (final code in [200, 301, 404, 429, 500]) {
      expect(
        looksLikeCfChallenge(status: code, cfMitigated: 'challenge', body: 'just a moment'),
        isFalse,
        reason: 'status $code should never be a challenge',
      );
    }
  });
}
