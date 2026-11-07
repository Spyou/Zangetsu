import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/features/downloads/episode_download_source_sheet.dart';

void main() {
  test(
    'download identity uses the detail ID when history only has a URL',
    () async {
      expect(
        await resolveEpisodeDownloadShowId(
          sourceId: 'source',
          showUrl: 'https://show.test/123',
          downloads: const [],
          loadShowId: () async => '123',
        ),
        '123',
      );
      expect(
        await resolveEpisodeDownloadShowId(
          sourceId: 'source',
          showUrl: 'https://show.test/123',
          knownId: '123',
          downloads: const [],
          loadShowId: () => throw StateError('must not fetch'),
        ),
        '123',
      );
    },
  );
  test(
    'existing download group is reused without another metadata request',
    () async {
      const record = DownloadRecord(
        id: 'download',
        sourceId: 'source',
        showId: 'saved-group',
        showTitle: 'Title',
        showUrl: 'https://show.test/title',
        episodeId: '1',
        episodeUrl: 'ep-1',
        episodeTitle: 'First',
        category: 'sub',
        quality: '1080p',
        createdAt: 0,
      );
      expect(
        await resolveEpisodeDownloadShowId(
          sourceId: 'source',
          showUrl: record.showUrl,
          downloads: const [record],
          loadShowId: () => throw StateError('must not fetch'),
        ),
        'saved-group',
      );
    },
  );
  test(
    'missing canonical ID fails instead of creating a URL-named group',
    () async {
      expect(
        resolveEpisodeDownloadShowId(
          sourceId: 'source',
          showUrl: 'https://show.test/123',
          downloads: const [],
          loadShowId: () async => '',
        ),
        throwsStateError,
      );
    },
  );

  const original = Episode(
    id: 'sub',
    title: 'Episode 2',
    url: 'sub',
    number: 2,
    season: 1,
  );
  const dub = Episode(
    id: 'dub',
    title: 'Episode 2 dubbed',
    url: 'dub',
    number: 2,
    season: 1,
  );
  test(
    'alternate cut matches season and episode instead of its list position',
    () {
      expect(
        matchDownloadEpisode(original, const [
          Episode(
            id: 'other',
            title: 'Other season',
            url: 'other',
            number: 2,
            season: 2,
          ),
          dub,
        ]),
        same(dub),
      );
    },
  );
  test(
    'ambiguous or missing alternate cut never downloads a different episode',
    () {
      expect(matchDownloadEpisode(original, const [dub, dub]), isNull);
      expect(matchDownloadEpisode(original, const []), isNull);
    },
  );
}
