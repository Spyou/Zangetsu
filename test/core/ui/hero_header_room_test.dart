import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/featured_hero.dart';

/// The room above the hero artwork used to be a flat 90 — status bar plus the
/// floating header. The header lives in a SafeArea, so on a phone with a tall
/// cutout it slid down as the status bar grew while the 90 stayed put, and the
/// wordmark and icons landed on the artwork.
void main() {
  test('the dev phone is unchanged, to the pixel', () {
    // 32dp inset, measured on device: 32 + 58 is exactly the old 90.
    expect(heroTopReserve(32), 90);
  });

  test('ordinary status bars keep the old layout', () {
    for (final inset in [0.0, 24.0, 28.0, 32.0]) {
      expect(heroTopReserve(inset), 90, reason: 'inset $inset must not move');
    }
  });

  test('a tall cutout pushes the card clear of the header', () {
    expect(heroTopReserve(48), 106);
    expect(heroTopReserve(64), 122);
  });

  test('the card always clears the header', () {
    // Header occupies the inset plus 8 padding + a 48 icon row.
    for (var inset = 0.0; inset <= 96; inset += 4) {
      expect(
        heroTopReserve(inset),
        greaterThanOrEqualTo(inset + 56),
        reason: 'header would overlap the artwork at inset $inset',
      );
    }
  });
}
