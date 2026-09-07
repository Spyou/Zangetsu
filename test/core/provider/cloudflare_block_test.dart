// A Cloudflare BLOCK and a Cloudflare CHALLENGE are both a 403 served by
// Cloudflare, and the block page loads the same challenge-platform script — so
// the challenge predicate says yes to both. That mattered: the app answered a
// block by opening a solver that can never clear it, because a block has no
// puzzle to solve.
//
// The bodies below are the shape of the real pages. `kwik.cx` refuses every
// HTTP/1.1 request whatever cookie it carries, and its 403 body carries BOTH
// "you have been blocked" and "challenge-platform" — which is exactly why the
// script marker cannot be the thing that decides.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

// Trimmed from a real kwik.cx 403 captured over HTTP/1.1.
const _blockPage = '''
<!DOCTYPE html><html><head><title>Attention Required! | Cloudflare</title>
<script src="/cdn-cgi/challenge-platform/h/g/scripts/jsd/main.js"></script>
</head><body><h1>Sorry, you have been blocked</h1>
<p>You are unable to access kwik.cx</p></body></html>
''';

// The interactive challenge the solver DOES clear.
const _challengePage = '''
<!DOCTYPE html><html><head><title>Just a moment...</title>
<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>
</head><body><div id="challenge-stage"></div>
<p>Enable JavaScript and cookies to continue</p></body></html>
''';

void main() {
  group('looksLikeCloudflareBlock', () {
    test('a real block page is a block', () {
      expect(looksLikeCloudflareBlock(403, _blockPage), isTrue);
    });

    test('a challenge is NOT a block, so the solver still gets it', () {
      // The whole point: this must stay false or the retry would steal every
      // challenge from the solver that can actually clear it.
      expect(looksLikeCloudflareBlock(403, _challengePage), isFalse);
    });

    test('the shared challenge-platform script cannot be the decider', () {
      // Both pages carry it. If the predicate keyed on that, the two would be
      // indistinguishable.
      expect(_blockPage.contains('challenge-platform'), isTrue);
      expect(_challengePage.contains('challenge-platform'), isTrue);
    });

    // A tie must go to the solver. If a page ever carries both wordings, the
    // safe reading is "challenge" — treating it as a block would hand it to a
    // lane that cannot solve anything, and the user would just see it fail.
    test('when a page says both, challenge wins', () {
      const ambiguous = 'Just a moment... Sorry, you have been blocked';
      expect(looksLikeCloudflareBlock(403, ambiguous), isFalse);
    });

    test('error code 1020 also counts', () {
      expect(
        looksLikeCloudflareBlock(403, 'Access denied. Error code: 1020'),
        isTrue,
      );
    });

    test('only a 403 — a 503 challenge is the solver\'s, not ours', () {
      expect(looksLikeCloudflareBlock(503, _blockPage), isFalse);
      expect(looksLikeCloudflareBlock(200, _blockPage), isFalse);
    });

    test('an ordinary forbidden page is left alone', () {
      expect(looksLikeCloudflareBlock(403, '<h1>403 Forbidden</h1>'), isFalse);
      expect(looksLikeCloudflareBlock(403, ''), isFalse);
    });

    test('wording is matched whatever the case', () {
      expect(
        looksLikeCloudflareBlock(403, 'SORRY, YOU HAVE BEEN BLOCKED'),
        isTrue,
      );
    });
  });
}
