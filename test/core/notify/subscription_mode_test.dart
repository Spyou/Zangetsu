import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/notify/subscription_store.dart';

Subscription sub({ContentMode mode = ContentMode.anime}) => Subscription(
  sourceId: 'src',
  url: 'https://x/show',
  title: 'Show',
  lastCount: 12,
  mode: mode,
);

void main() {
  group('Subscription mode', () {
    test('round-trips so an alert knows what it is announcing', () {
      for (final m in ContentMode.values) {
        expect(Subscription.fromMap(sub(mode: m).toMap()).mode, m);
      }
    });

    test('a subscription saved before modes existed reads as anime', () {
      // Anything already subscribed keeps working and keeps saying "episode",
      // rather than loading as a null mode and blowing up.
      final old = sub().toMap()..remove('mode');
      expect(Subscription.fromMap(old).mode, ContentMode.anime);
      expect(Subscription.fromMap(old).isReading, isFalse);
    });

    test('an unknown mode falls back instead of throwing', () {
      final j = sub().toMap()..['mode'] = 'audiobook';
      expect(Subscription.fromMap(j).mode, ContentMode.anime);
    });

    test('reading modes pick the chapter wording', () {
      expect(sub(mode: ContentMode.manga).unit, 'Chapter');
      expect(sub(mode: ContentMode.novel).unit, 'Chapter');
      expect(sub(mode: ContentMode.anime).unit, 'Episode');
      expect(sub(mode: ContentMode.manga).isReading, isTrue);
    });

    test('copyWith keeps the mode when only the count moves', () {
      // The checker calls this after every sweep; losing the mode there would
      // silently turn chapter alerts back into episode alerts.
      final s = sub(mode: ContentMode.novel).copyWith(lastCount: 40);
      expect(s.mode, ContentMode.novel);
      expect(s.lastCount, 40);
    });
  });
}
