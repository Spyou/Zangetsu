import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  test('provider id is a tickable info-overlay field', () {
    final entry = kPlayerInfoFields.where((f) => f.$1 == 'provider');
    expect(entry, hasLength(1));
    expect(entry.single.$2, 'Provider');
  });

  group('providerInfoLabel', () {
    test('pairs the display name with an opaque numeric id', () {
      expect(
        providerInfoLabel('ani:7667', (_) => 'HiAnime'),
        'HiAnime (ani:7667)',
      );
    });

    test('keeps a readable slug exact with its name', () {
      expect(
        providerInfoLabel('cs:anikoto', (_) => 'AniKoto'),
        'AniKoto (cs:anikoto)',
      );
    });

    test('falls back to the bare id when no name resolves', () {
      expect(providerInfoLabel('cs:x', (_) => null), 'cs:x');
      expect(providerInfoLabel('cs:x', (_) => ''), 'cs:x');
      expect(providerInfoLabel('cs:x', (_) => 'cs:x'), 'cs:x');
      expect(
        providerInfoLabel('cs:x', (_) => throw StateError('no repo')),
        'cs:x',
      );
    });
  });
}
