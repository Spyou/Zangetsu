import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/reader_image_budget.dart';

/// The app-wide image budget is 80MB, sized for covers. A manga page keeps its
/// full aspect (ResizeImage caps width only), so one slice can run to tens of
/// megabytes — measured on device the cache sat pinned at 79.4/80MB mid-scroll,
/// evicting a page for every page it took in. Frames were fine; the lag was
/// pages being thrown away and decoded again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(ReaderImageBudget.debugReset);

  group('budgetFor', () {
    test('a small phone is left completely alone', () {
      // 0 means "do not touch the app budget". There is an Android 8 device in
      // the shared reports that cannot even load libmpv; it must not be asked
      // to hold 200MB of bitmaps.
      expect(ReaderImageBudget.budgetFor(1800), 0);
      expect(ReaderImageBudget.budgetFor(2048), 0);
      expect(ReaderImageBudget.budgetFor(0), 0, reason: 'unknown RAM');
    });

    test('the budget climbs with the RAM actually present', () {
      expect(ReaderImageBudget.budgetFor(3000), 128 << 20);
      expect(ReaderImageBudget.budgetFor(4096), 192 << 20);
      expect(ReaderImageBudget.budgetFor(6144), 256 << 20);
      expect(ReaderImageBudget.budgetFor(8192), 320 << 20);
    });

    test('it never goes DOWN from the app budget', () {
      // Every non-zero step has to beat the 80MB the app already allows, or
      // opening a chapter would shrink the cache.
      for (final ram in [3000, 4096, 6144, 8192, 16384]) {
        expect(ReaderImageBudget.budgetFor(ram), greaterThan(80 << 20),
            reason: '$ram MB');
      }
    });
  });

  group('acquire / release', () {
    final cache = PaintingBinding.instance.imageCache;

    test('raises while reading and puts it back on the way out', () async {
      cache.maximumSizeBytes = 80 << 20;
      cache.maximumSize = 300;
      ReaderImageBudget.debugRamMb = 6144;

      await ReaderImageBudget.acquire();
      expect(cache.maximumSizeBytes, 256 << 20);
      expect(cache.maximumSize, 600,
          reason: 'a chapter of small pages hits 300 images before 256MB');

      ReaderImageBudget.release();
      expect(cache.maximumSizeBytes, 80 << 20);
      expect(cache.maximumSize, 300);
    });

    test('a low-RAM device keeps the app budget untouched', () async {
      cache.maximumSizeBytes = 80 << 20;
      ReaderImageBudget.debugRamMb = 2048;
      await ReaderImageBudget.acquire();
      expect(cache.maximumSizeBytes, 80 << 20);
      ReaderImageBudget.release();
      expect(cache.maximumSizeBytes, 80 << 20);
    });

    test('nesting raises once and restores once', () async {
      // Pulling the next chapter in can put two readers on screen at the same
      // moment; the inner one closing must not hand the memory back while the
      // outer one is still reading.
      cache.maximumSizeBytes = 80 << 20;
      ReaderImageBudget.debugRamMb = 6144;

      await ReaderImageBudget.acquire();
      await ReaderImageBudget.acquire();
      expect(cache.maximumSizeBytes, 256 << 20);

      ReaderImageBudget.release();
      expect(cache.maximumSizeBytes, 256 << 20, reason: 'still reading');
      ReaderImageBudget.release();
      expect(cache.maximumSizeBytes, 80 << 20);
    });

    test('release without acquire does nothing', () {
      cache.maximumSizeBytes = 80 << 20;
      ReaderImageBudget.release();
      expect(cache.maximumSizeBytes, 80 << 20);
    });
  });
}
