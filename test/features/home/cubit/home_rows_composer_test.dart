import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_row.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/cubit/home_rows_composer.dart';

MediaItem _item(String t) => MediaItem(
  id: t,
  title: t,
  cover: null,
  url: 'zm://anime/mal:1',
  type: ProviderType.anime,
  sourceId: 'zm',
);

/// A Z Mode section: `more.sourceId == 'zm'`, like every metadata row.
HomeSection _zm(String t) => HomeSection(
  title: t,
  items: [_item(t)],
  more: const BrowseMore(sourceId: 'zm', kind: 'zm_home'),
);

/// A CloudStream section: `more.sourceId == 'cs:x'` — first section does NOT
/// repeat as a row on the phone.
HomeSection _cs(String t) => HomeSection(
  title: t,
  items: [_item(t)],
  more: const BrowseMore(sourceId: 'cs:Example', kind: 'cs_mainpage'),
);

TrackerListItem _entry(String title, {WatchStatus status = WatchStatus.watching}) =>
    TrackerListItem(
      item: MediaItem(
        id: title,
        title: title,
        cover: null,
        url: '',
        type: ProviderType.anime,
        sourceId: '',
        malId: 1,
      ),
      status: status,
    );

void main() {
  group('layoutKeyFor', () {
    test('Z Mode layouts key by provider + browse kind', () {
      expect(
        layoutKeyFor(
          sourceId: 'zm',
          zModeOn: true,
          browseKind: ZKind.anime,
        ),
        'anilist::anime',
      );
      expect(
        layoutKeyFor(
          sourceId: 'zm',
          zModeOn: true,
          browseKind: ZKind.anime,
          malPreferred: true,
        ),
        'mal::anime',
      );
      expect(
        layoutKeyFor(
          sourceId: 'zm',
          zModeOn: true,
          browseKind: ZKind.manga,
          malPreferred: true,
        ),
        'mal::manga',
      );
      expect(
        layoutKeyFor(
          sourceId: 'zm',
          zModeOn: true,
          browseKind: ZKind.movie,
        ),
        'tmdb::movie',
      );
      expect(
        layoutKeyFor(
          sourceId: 'zm',
          zModeOn: true,
          browseKind: ZKind.tv,
          simklPreferred: true,
        ),
        'simkl::tv',
      );
    });

    test('a source-backed home keys by source id', () {
      expect(
        layoutKeyFor(sourceId: 'cs:Example', zModeOn: false, browseKind: null),
        'source:cs:Example',
      );
      // Z Mode off wins even if a kind was passed by mistake.
      expect(
        layoutKeyFor(sourceId: 'cs:Example', zModeOn: false, browseKind: ZKind.anime),
        'source:cs:Example',
      );
    });
  });

  group('providerRowSections — today\'s hero/row split, verbatim', () {
    test('Z Mode keeps every section as a row (Trending repeats below the banner)', () {
      final sections = [_zm('Trending'), _zm('Popular'), _zm('Top rated')];
      expect(providerRowSections(sections, isTv: false), sections);
    });

    test('the phone drops a non-repeating first section (CloudStream hero dup)',
        () {
      final sections = [_cs('Featured'), _cs('Latest'), _cs('Popular')];
      expect(
        providerRowSections(sections, isTv: false).map((s) => s.title),
        ['Latest', 'Popular'],
      );
    });

    test('a single section stays a row so there is something to browse', () {
      final sections = [_cs('Latest')];
      expect(providerRowSections(sections, isTv: false), sections);
    });

    test('TV never drops — every section is a rail', () {
      final sections = [_cs('Featured'), _cs('Latest')];
      expect(providerRowSections(sections, isTv: true), sections);
    });
  });

  group('sanitizeLayout', () {
    final available = availableRowIds(
      [_zm('Trending'), _zm('Popular')],
      withTrackerRows: true,
    );

    test('an empty saved list resolves to the full default arrangement', () {
      final out = sanitizeLayout([], available);
      expect(out.map(encodeRowEntry), defaultLayout(
        ['section:Trending', 'section:Popular'],
        withTrackerRows: true,
      ));
    });

    test('unknown ids drop; duplicates collapse; hidden marks survive', () {
      final out = sanitizeLayout([
        'local:continue',
        'local:continue', // dup
        'section:Gone', // renamed away since the save
        '!tracker:watching', // hidden by the user
        'section:Popular',
        'section:Trending',
      ], available);
      expect(out.map(encodeRowEntry), [
        '!tracker:continue', // missing structural rows re-enter hidden, on top
        '!tracker:new-episodes',
        '!tracker:planning',
        '!tracker:paused',
        '!tracker:dropped',
        'local:continue',
        '!tracker:watching',
        'section:Popular',
        'section:Trending',
      ]);
    });

    test('a section added since the save re-enters visible, at the end', () {
      final out = sanitizeLayout(['local:continue'], available);
      expect(out.last, const HomeRowEntry('section:Popular', false));
      expect(out.map((e) => e.id).contains('section:Trending'), isTrue);
    });

    test('tracker ids sanitize against a layout that cannot have them', () {
      final tmdbAvailable = availableRowIds([_zm('Now playing')],
          withTrackerRows: false);
      final out = sanitizeLayout(['tracker:watching', 'local:continue'],
          tmdbAvailable);
      expect(out.map((e) => e.id), ['local:continue', 'section:Now playing']);
    });
  });

  group('mergeHomeRows', () {
    final sections = [_zm('Trending'), _zm('Popular this season'), _zm('Top rated')];

    test('DEFAULT = today\'s home: local row + every section, no tracker rows',
        () {
      final rows = mergeHomeRows(
        layout: sanitizeLayout(
          defaultLayout(
            sections.map((s) => 'section:${s.title}').toList(),
            withTrackerRows: true,
          ),
          availableRowIds(sections, withTrackerRows: true),
        ),
        rowSections: providerRowSections(sections, isTv: false),
        trackerRows: [
          // The tracker DID answer with rows — default layout still hides
          // them all, so none may render.
          TrackerContinueHomeRow(items: [_entry('One Piece')], trackerName: 'AniList'),
          NewEpisodesHomeRow(items: [_entry('Bleach')], trackerName: 'AniList'),
          TrackerListHomeRow(
            status: WatchStatus.watching,
            items: [_entry('Naruto')],
            trackerName: 'AniList',
          ),
        ],
      );
      expect(rows.map((r) => r.id), [
        'local:continue',
        'section:Trending',
        'section:Popular this season',
        'section:Top rated',
      ]);
    });

    test('an enabled tracker row renders where the user put it', () {
      final rows = mergeHomeRows(
        layout: sanitizeLayout([
          'tracker:watching',
          'local:continue',
        ], availableRowIds(sections, withTrackerRows: true)),
        rowSections: providerRowSections(sections, isTv: false),
        trackerRows: [
          TrackerListHomeRow(
            status: WatchStatus.watching,
            items: [_entry('Naruto')],
            trackerName: 'AniList',
          ),
          // planning has no items → dropped silently even if enabled
          TrackerListHomeRow(
            status: WatchStatus.planning,
            items: const [],
            trackerName: 'AniList',
          ),
        ],
      );
      expect(rows.map((r) => r.id), [
        'tracker:watching',
        'local:continue',
        'section:Trending',
        'section:Popular this season',
        'section:Top rated',
      ]);
      expect(rows.first, isA<TrackerListHomeRow>());
    });

    test('an enabled tracker row with NO data at all simply vanishes', () {
      final rows = mergeHomeRows(
        layout: sanitizeLayout(
          ['local:continue', 'tracker:watching', 'tracker:new-episodes'],
          availableRowIds(sections, withTrackerRows: true),
        ),
        rowSections: providerRowSections(sections, isTv: false),
        trackerRows: const [],
      );
      expect(rows.map((r) => r.id), [
        'local:continue',
        'section:Trending',
        'section:Popular this season',
        'section:Top rated',
      ]);
    });

    test('parse/encode round-trip the hidden mark', () {
      expect(parseRowEntry('tracker:watching'),
          const HomeRowEntry('tracker:watching', false));
      expect(parseRowEntry('!section:Trending'),
          const HomeRowEntry('section:Trending', true));
      expect(encodeRowEntry(const HomeRowEntry('section:Trending', true)),
          '!section:Trending');
    });
  });
}
