import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';

MyListEntry entry({
  ProviderType type = ProviderType.anime,
  int? progress,
  int? totalEpisodes,
  int? nextAiringEpisode,
  bool tmdbIsTv = false,
  bool isUnreleased = false,
}) => MyListEntry(
  MediaItem(id: 'x', title: 'X', url: '', type: type, sourceId: ''),
  null,
  progress: progress,
  tmdbIsTv: tmdbIsTv,
  totalEpisodes: totalEpisodes,
  nextAiringEpisode: nextAiringEpisode,
  isUnreleased: isUnreleased,
);

void main() {
  group('behindCount', () {
    test('airing show: released is one behind next airing', () {
      // Ep 11 airs next → 10 out, watched 7 → 3 behind.
      expect(
        behindCount(
          entry(progress: 7, totalEpisodes: 24, nextAiringEpisode: 11),
        ),
        3,
      );
    });

    test('finished show: total minus progress', () {
      expect(behindCount(entry(progress: 20, totalEpisodes: 24)), 4);
    });

    test('caught up shows no chip', () {
      expect(behindCount(entry(progress: 24, totalEpisodes: 24)), isNull);
      expect(
        behindCount(
          entry(progress: 10, totalEpisodes: 24, nextAiringEpisode: 11),
        ),
        isNull,
      );
    });

    test('unknown totals show no chip (never guess)', () {
      expect(behindCount(entry(progress: 5)), isNull);
      expect(
        behindCount(entry(progress: 5, nextAiringEpisode: 1)),
        isNull, // nothing released yet
      );
    });

    test('one-shot movies never chip', () {
      expect(
        behindCount(
          entry(type: ProviderType.movie, progress: null, totalEpisodes: 1),
        ),
        isNull,
      );
      // ...while TV series filed as movies still do.
      expect(
        behindCount(
          entry(
            type: ProviderType.movie,
            progress: 3,
            totalEpisodes: 10,
            tmdbIsTv: true,
          ),
        ),
        7,
      );
    });

    test('own list (no counts at all) shows no chip', () {
      expect(behindCount(entry()), isNull);
    });
  });

  group('behindLabel', () {
    test('formats behind over released', () {
      expect(
        behindLabel(
          entry(progress: 7, totalEpisodes: 24, nextAiringEpisode: 11),
        ),
        '3/10',
      );
      expect(behindLabel(entry(progress: 20, totalEpisodes: 24)), '4/24');
    });

    test('caught up shows the full count', () {
      expect(behindLabel(entry(progress: 24, totalEpisodes: 24)), '24/24');
    });

    test('never started shows watched zero', () {
      expect(behindLabel(entry(totalEpisodes: 12)), '0/12');
    });

    test('null whenever there is no chip', () {
      expect(behindLabel(entry()), isNull);
      expect(
        behindLabel(entry(type: ProviderType.movie, totalEpisodes: 1)),
        isNull,
      );
      expect(behindLabel(entry(progress: 5)), isNull);
    });

    test('unreleased shows Soon instead of nothing', () {
      expect(behindLabel(entry(isUnreleased: true)), 'Soon');
      expect(behindLabel(entry(isUnreleased: true), 'Bientôt'), 'Bientôt');
    });
  });
}
