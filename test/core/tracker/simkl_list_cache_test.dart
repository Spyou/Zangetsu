import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';

/// `/sync/all-items?extended=full` returns the whole library. A shared log
/// (ref MXW8BS) caught it fetching 1024 items 37 times in two hours — three of
/// those inside three seconds — because HomeCubit drops its own cache on every
/// source switch, retry and refresh. Simkl bills a daily request budget, so
/// that is how tracking quietly dies mid-session.
void main() {
  final t0 = DateTime(2026, 9, 15, 12, 0, 0);

  group('the cached library is served only while it is fresh', () {
    test('nothing cached is never fresh', () {
      expect(SimklService.listCacheFresh(null, t0), isFalse);
    });

    test('a burst of home reloads reuses one fetch', () {
      // The three-in-three-seconds case from the report.
      expect(
        SimklService.listCacheFresh(t0, t0.add(const Duration(seconds: 3))),
        isTrue,
      );
    });

    test('it lapses, so a change made on simkl.com still lands', () {
      expect(
        SimklService.listCacheFresh(
          t0,
          t0.add(SimklService.listCacheTtl + const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('the window is short enough not to hide someone else\'s edit', () {
      expect(
        SimklService.listCacheTtl,
        lessThanOrEqualTo(const Duration(minutes: 5)),
      );
    });
  });
}
