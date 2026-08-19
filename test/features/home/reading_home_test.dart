// Task 12 Parts A + B:
//  - Home's Continue Watching row swaps to Continue Reading in a reading
//    mode (manga/novel), fed by ReadHistory; anime mode renders exactly
//    today's WatchHistory-backed row (ContinueWatchingRow/ContinueSection,
//    home_screen.dart + continue_section.dart).
//  - My List's grid filters by ContentMode.matchesProvider(item.type); the
//    anime-mode filter UI (segmented control, type-filter sheet) is
//    untouched — matchesProvider is a no-op there (anime OR movie).
//
// ContinueWatchingRow/ContinueReadingRow (the actual card content — title,
// subtitle, tap wiring) are pumped directly against a resolved list.
// ContinueSection's gating (login / box-not-open) is exercised without
// opening a real Hive box; its LIVE branch selection (box open, real
// ValueListenableBuilder mount) is exercised in the group below with
// `tester.runAsync()` — real Hive I/O called directly inside a `testWidgets`
// body (no runAsync) hangs indefinitely in this environment (bare
// `Hive.init`/`openBox`, nothing feature-specific); `runAsync` is the
// standard Flutter-test fix for exactly this class of hang, and it works
// here. See task-12-report.md for the full writeup.
//
// The real HomeScreen isn't pumped at all — its initState fires a one-time,
// un-DI'd update-check + real network call (UpdateService()) and opens
// community/announcement Hive boxes, none of which this feature touches.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/ui/content_row.dart';
import 'package:watch_app/core/ui/continue_card.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/home/continue_section.dart';
import 'package:watch_app/features/home/home_screen.dart' show readerFor;
import 'package:watch_app/features/home/my_list_screen.dart';
import 'package:watch_app/features/reader/manga_reader_screen.dart';
import 'package:watch_app/features/reader/novel_reader_screen.dart';

// ── Shared fakes ─────────────────────────────────────────────────────────────

/// Bare [ContentModeCubit] stand-in: real [Cubit] behaviour (emit/state/
/// stream) via `extends`, everything ContentModeCubit-specific (setMode,
/// etc.) unreachable via `noSuchMethod` — nothing under test calls those.
class _FakeContentModeCubit extends Cubit<ContentMode>
    implements ContentModeCubit {
  _FakeContentModeCubit(super.initial);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeMyListStore implements MyListStore {
  _FakeMyListStore(this._items) : revision = ValueNotifier<int>(0);
  final List<MediaItem> _items;

  @override
  final ValueNotifier<int> revision;

  @override
  List<MediaItem> all() => List<MediaItem>.from(_items);

  @override
  bool contains(MediaItem m) => _items.any((i) => i.id == m.id);

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeListStatusStore implements ListStatusStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  @override
  WatchStatus? statusOf(MediaItem m) => null;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Bare authenticated [AuthCubit] stand-in — only needed to reach
/// MyListScreen's `_empty()` branch (gated on `context.watch<AuthCubit>()`),
/// which the existing mode-filter tests never hit (their fixture list is
/// never actually empty).
class _FakeAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _FakeAuthCubit(super.initial);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  // ── Part A: Continue Watching / Continue Reading row content ─────────────
  // Pumped directly (no Hive) — this is what actually renders the card.

  group('ContinueWatchingRow / ContinueReadingRow content', () {
    // ContentRow wraps every card in RevealItem, which reads sl<AppMode>()
    // unconditionally (list-animation gating) — needed even though nothing
    // in these tests is TV-specific.
    setUp(() async {
      await sl.reset();
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    });

    tearDown(() async {
      await sl.reset();
    });

    testWidgets(
      'ContinueWatchingRow renders the title, an Episode subtitle, resumes '
      'on tap/long-press, and passes every ContinueCard/ContentRow param '
      'through unchanged — the anime row, unchanged (regression)',
      (tester) async {
        HistoryEntry? resumed;
        HistoryEntry? longPressed;
        final entry = HistoryEntry(
          sourceId: 'src',
          showId: 'show1',
          showTitle: 'Anime Show',
          cover: 'https://example.com/cover.jpg',
          coverHeaders: const {'x-h': '1'},
          thumbnail: 'https://example.com/thumb.jpg',
          showUrl: '/show1',
          category: 'sub',
          episodeId: 'e1',
          episodeNumber: 3,
          episodeUrl: '/e1',
          position: const Duration(minutes: 6),
          duration: const Duration(minutes: 24),
          updatedAt: 1,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ContinueWatchingRow(
                    history: [entry],
                    onSeeAll: () {},
                    onResume: (e) => resumed = e,
                    onLongPress: (e) => longPressed = e,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Continue Watching'), findsOneWidget);
        expect(find.text('Episode 3'), findsOneWidget);

        // Pin every ContinueCard param the move could have dropped/swapped.
        final card = tester.widget<ContinueCard>(find.byType(ContinueCard));
        expect(card.imageUrl, entry.thumbnail); // thumbnail wins over cover
        expect(card.headers, entry.coverHeaders);
        expect(card.progress, 0.25); // 6min / 24min
        expect(card.cellWidth, 190);

        // Row geometry — compact 16:9 landscape (episode thumbnails).
        final row = tester.widget<ContentRow>(find.byType(ContentRow));
        expect(row.itemWidth, 190);
        expect(row.itemHeight, 107);

        await tester.tap(find.text('Anime Show'));
        expect(resumed?.showId, 'show1');

        await tester.longPress(find.text('Anime Show'));
        expect(longPressed?.showId, 'show1');
      },
    );

    testWidgets(
      'ContinueWatchingRow falls back to the portrait cover when there is '
      'no episode thumbnail',
      (tester) async {
        final entry = HistoryEntry(
          sourceId: 'src',
          showId: 'show1',
          showTitle: 'Anime Show',
          cover: 'https://example.com/cover.jpg',
          showUrl: '/show1',
          category: 'sub',
          episodeId: 'e1',
          episodeNumber: null,
          episodeUrl: '/e1',
          position: Duration.zero,
          duration: const Duration(minutes: 24),
          updatedAt: 1,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ContinueWatchingRow(
                    history: [entry],
                    onSeeAll: () {},
                    onResume: (_) {},
                    onLongPress: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final card = tester.widget<ContinueCard>(find.byType(ContinueCard));
        expect(card.imageUrl, entry.cover);
      },
    );

    testWidgets(
      'ContinueWatchingRow renders nothing for an empty history (regression '
      '— matches the original "hide when empty" behaviour)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ContinueWatchingRow(
                    history: const [],
                    onSeeAll: () {},
                    onResume: (_) {},
                    onLongPress: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Continue Watching'), findsNothing);
      },
    );

    testWidgets(
      'ContinueReadingRow renders the title, a Chapter subtitle, and '
      'resumes on tap',
      (tester) async {
        ReadEntry? resumed;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ContinueReadingRow(
                    history: [
                      ReadEntry(
                        sourceId: 'src',
                        showId: 'show2',
                        title: 'Novel Title',
                        chapterId: 'c5',
                        chapterNumber: 5,
                        chapterUrl: '/c5',
                        pos: 3,
                        total: 20,
                        updatedMs: 1,
                        type: ProviderType.novel,
                      ),
                    ],
                    onResumeReading: (e) => resumed = e,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Continue Reading'), findsOneWidget);
        expect(find.text('Chapter 5'), findsOneWidget);
        expect(find.text('Continue Watching'), findsNothing);

        // Compact horizontal "keep reading" chip — its own small shape, NOT
        // Continue Watching's 230x129 landscape card (which would letterbox a
        // portrait cover) and not the full-poster card either.
        final row = tester.widget<ContentRow>(find.byType(ContentRow));
        expect(row.itemWidth, 236);
        expect(row.itemHeight, 76);
        expect(find.byType(ContinueReadingCard), findsOneWidget);
        expect(find.byType(ContinueCard), findsNothing); // not the anime card

        await tester.tap(find.text('Novel Title'));
        expect(resumed?.showId, 'show2');
      },
    );
  });

  // ── Part A: ContinueSection gating (login / box-open guard) ──────────────
  // No Hive box is ever opened here, so Hive.isBoxOpen() is always false —
  // exercising exactly the "signed-out / test-env" guard branch the
  // original code's comment described, for both modes.

  group('ContinueSection gating', () {
    setUp(() async {
      await sl.reset();
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    });

    tearDown(() async {
      await sl.reset();
    });

    Future<void> pumpGated(
      WidgetTester tester, {
      required bool loggedIn,
      required ContentMode mode,
    }) async {
      if (sl.isRegistered<ContentModeCubit>()) {
        sl.unregister<ContentModeCubit>();
      }
      sl.registerSingleton<ContentModeCubit>(_FakeContentModeCubit(mode));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                ContinueSection(
                  loggedIn: loggedIn,
                  onResume: (_) {},
                  onLongPress: (_) {},
                  onSeeAll: () {},
                  onResumeReading: (_) {},
                  onLongPressReading: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('signed out renders nothing in anime mode', (tester) async {
      await pumpGated(tester, loggedIn: false, mode: ContentMode.anime);
      expect(find.text('Continue Watching'), findsNothing);
      expect(find.text('Continue Reading'), findsNothing);
    });

    testWidgets('signed out renders nothing in a reading mode',
        (tester) async {
      await pumpGated(tester, loggedIn: false, mode: ContentMode.novel);
      expect(find.text('Continue Watching'), findsNothing);
      expect(find.text('Continue Reading'), findsNothing);
    });

    testWidgets(
      'signed in but the box was never opened (production opens it at '
      'boot) still renders nothing — never throws',
      (tester) async {
        await pumpGated(tester, loggedIn: true, mode: ContentMode.anime);
        expect(find.text('Continue Watching'), findsNothing);
        await pumpGated(tester, loggedIn: true, mode: ContentMode.manga);
        expect(find.text('Continue Reading'), findsNothing);
      },
    );
  });

  // ── Part A: ContinueSection's live branch selection ───────────────────────
  // Proves `mode.isReading ? _readingRow() : _watchingRow()` actually picks
  // the right row widget when the box IS open — the one path the gating
  // group above can't reach (it never opens a box, by design).
  //
  // Real Hive I/O inside a `testWidgets` body must run through
  // `tester.runAsync()` — without it, `Hive.init`/`openBox` hang
  // indefinitely (reproduced in isolation: a bare `Hive.init` + `openBox`
  // called directly inside a `testWidgets` callback never completes; the
  // identical calls complete instantly either in a plain `test()` or when
  // wrapped in `runAsync`). That's the actual root cause of the hang
  // described in Part A's file-level comment above — not something
  // specific to `ValueListenableBuilder` or this feature's code.

  group("ContinueSection's live branch selection", () {
    setUp(() async {
      await sl.reset();
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    });

    tearDown(() async {
      await sl.reset();
    });

    testWidgets(
      'anime mode with the box open renders ContinueWatchingRow, not '
      'ContinueReadingRow',
      (tester) async {
        late Directory dir;
        await tester.runAsync(() async {
          dir = await Directory.systemTemp.createTemp('continue_section_live');
          Hive.init(dir.path);
          await WatchHistory.init();
          await ReadHistory.init();
        });
        sl.registerSingleton<WatchHistory>(
          WatchHistory(SupabaseService(), () => null),
        );
        sl.registerSingleton<ReadHistory>(
          ReadHistory(SupabaseService(), () => null),
        );
        await tester.runAsync(
          () => sl<WatchHistory>().save(
            HistoryEntry(
              sourceId: 'src',
              showId: 'show1',
              showTitle: 'Anime Show',
              showUrl: '/show1',
              category: 'sub',
              episodeId: 'e1',
              episodeNumber: 1,
              episodeUrl: '/e1',
              position: const Duration(minutes: 1),
              duration: const Duration(minutes: 24),
              updatedAt: 1,
            ),
          ),
        );
        sl.registerSingleton<ContentModeCubit>(
          _FakeContentModeCubit(ContentMode.anime),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ContinueSection(
                    loggedIn: true,
                    onResume: (_) {},
                    onLongPress: (_) {},
                    onSeeAll: () {},
                    onResumeReading: (_) {},
                    onLongPressReading: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ContinueWatchingRow), findsOneWidget);
        expect(find.byType(ContinueReadingRow), findsNothing);
        expect(find.text('Continue Watching'), findsOneWidget);

        await tester.runAsync(() async {
          await Hive.deleteFromDisk();
          if (await dir.exists()) await dir.delete(recursive: true);
        });
      },
    );

    testWidgets(
      'a reading mode with the box open renders ContinueReadingRow, not '
      'ContinueWatchingRow',
      (tester) async {
        late Directory dir;
        await tester.runAsync(() async {
          dir = await Directory.systemTemp.createTemp('continue_section_live');
          Hive.init(dir.path);
          await WatchHistory.init();
          await ReadHistory.init();
        });
        sl.registerSingleton<WatchHistory>(
          WatchHistory(SupabaseService(), () => null),
        );
        sl.registerSingleton<ReadHistory>(
          ReadHistory(SupabaseService(), () => null),
        );
        await tester.runAsync(
          () => sl<ReadHistory>().save(
            ReadEntry(
              sourceId: 'src',
              showId: 'show2',
              title: 'Novel Title',
              chapterId: 'c1',
              chapterNumber: 1,
              chapterUrl: '/c1',
              pos: 1,
              total: 20,
              updatedMs: 1,
              type: ProviderType.novel,
            ),
          ),
        );
        sl.registerSingleton<ContentModeCubit>(
          _FakeContentModeCubit(ContentMode.novel),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ContinueSection(
                    loggedIn: true,
                    onResume: (_) {},
                    onLongPress: (_) {},
                    onSeeAll: () {},
                    onResumeReading: (_) {},
                    onLongPressReading: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ContinueReadingRow), findsOneWidget);
        expect(find.byType(ContinueWatchingRow), findsNothing);
        expect(find.text('Continue Reading'), findsOneWidget);

        await tester.runAsync(() async {
          await Hive.deleteFromDisk();
          if (await dir.exists()) await dir.delete(recursive: true);
        });
      },
    );
  });

  // ── Part B: My List mode filter ───────────────────────────────────────────

  group('MyListScreen mode filter', () {
    const animeItem = MediaItem(
      id: 'a1',
      title: 'Anime Show',
      url: '/a1',
      type: ProviderType.anime,
      sourceId: 's',
    );
    const movieItem = MediaItem(
      id: 'm1',
      title: 'Movie Show',
      url: '/m1',
      type: ProviderType.movie,
      sourceId: 's',
    );
    const mangaItem = MediaItem(
      id: 'g1',
      title: 'Manga Title',
      url: '/g1',
      type: ProviderType.manga,
      sourceId: 's',
    );
    const novelItem = MediaItem(
      id: 'n1',
      title: 'Novel Title',
      url: '/n1',
      type: ProviderType.novel,
      sourceId: 's',
    );

    setUp(() async {
      await sl.reset();
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));
      sl.registerSingleton<TrackerHub>(TrackerHub(const []));
      sl.registerSingleton<MyListStore>(
        _FakeMyListStore([animeItem, movieItem, mangaItem, novelItem]),
      );
      sl.registerSingleton<ListStatusStore>(_FakeListStatusStore());
    });

    tearDown(() async {
      await sl.reset();
    });

    testWidgets(
      'anime mode shows anime + movie items and hides manga/novel — the '
      "hard constraint: anime mode's own library view is unchanged",
      (tester) async {
        sl.registerSingleton<ContentModeCubit>(
          _FakeContentModeCubit(ContentMode.anime),
        );

        await tester.pumpWidget(const MaterialApp(home: MyListScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Anime Show'), findsOneWidget);
        expect(find.text('Movie Show'), findsOneWidget);
        expect(find.text('Manga Title'), findsNothing);
        expect(find.text('Novel Title'), findsNothing);
      },
    );

    testWidgets(
      'manga mode shows only the manga item, hiding anime/movie/novel',
      (tester) async {
        sl.registerSingleton<ContentModeCubit>(
          _FakeContentModeCubit(ContentMode.manga),
        );

        await tester.pumpWidget(const MaterialApp(home: MyListScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Manga Title'), findsOneWidget);
        expect(find.text('Anime Show'), findsNothing);
        expect(find.text('Movie Show'), findsNothing);
        expect(find.text('Novel Title'), findsNothing);
      },
    );

    testWidgets(
      'novel mode shows only the novel item, hiding anime/movie/manga',
      (tester) async {
        sl.registerSingleton<ContentModeCubit>(
          _FakeContentModeCubit(ContentMode.novel),
        );

        await tester.pumpWidget(const MaterialApp(home: MyListScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Novel Title'), findsOneWidget);
        expect(find.text('Anime Show'), findsNothing);
        expect(find.text('Movie Show'), findsNothing);
        expect(find.text('Manga Title'), findsNothing);
      },
    );
  });

  // ── Part B: My List empty-state wording (Task E2) ─────────────────────────
  // Both of MyListScreen's EmptyStates were watch-centric wording no matter
  // the content mode. `_empty()` (truly nothing in the list, any type) needs
  // a logged-in AuthCubit above it — the mode-filter group above never hits
  // that branch because its fixture list is never actually empty.

  group('MyListScreen empty-state wording', () {
    const authedState = AuthState(
      status: AuthStatus.authenticated,
      user: AuthUser(id: 'u1', name: 'Tester', email: 't@example.com'),
    );

    Widget authed(Widget child) => MaterialApp(
      home: BlocProvider<AuthCubit>.value(
        value: _FakeAuthCubit(authedState),
        child: child,
      ),
    );

    setUp(() async {
      await sl.reset();
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));
      sl.registerSingleton<TrackerHub>(TrackerHub(const []));
      sl.registerSingleton<ListStatusStore>(_FakeListStatusStore());
    });

    tearDown(() async {
      await sl.reset();
    });

    testWidgets(
      'anime mode, list truly empty — unchanged wording, no button '
      '(regression)',
      (tester) async {
        sl.registerSingleton<MyListStore>(_FakeMyListStore(const []));
        sl.registerSingleton<ContentModeCubit>(
          _FakeContentModeCubit(ContentMode.anime),
        );

        await tester.pumpWidget(authed(const MyListScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Titles you add appear here'), findsOneWidget);
        expect(find.byType(FilledButton), findsNothing);
      },
    );

    testWidgets('manga mode, list truly empty — reading-specific wording',
        (tester) async {
      sl.registerSingleton<MyListStore>(_FakeMyListStore(const []));
      sl.registerSingleton<ContentModeCubit>(
        _FakeContentModeCubit(ContentMode.manga),
      );

      await tester.pumpWidget(authed(const MyListScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Manga you add appear here'), findsOneWidget);
      expect(find.text('Titles you add appear here'), findsNothing);
    });

    testWidgets('novel mode, list truly empty — reading-specific wording',
        (tester) async {
      sl.registerSingleton<MyListStore>(_FakeMyListStore(const []));
      sl.registerSingleton<ContentModeCubit>(
        _FakeContentModeCubit(ContentMode.novel),
      );

      await tester.pumpWidget(authed(const MyListScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Novels you add appear here'), findsOneWidget);
    });

    testWidgets(
      'anime mode, list has only manga/novel items (filtered to nothing) — '
      'unchanged "Nothing here in this filter" wording (regression)',
      (tester) async {
        const mangaItem = MediaItem(
          id: 'g1',
          title: 'Manga Title',
          url: '/g1',
          type: ProviderType.manga,
          sourceId: 's',
        );
        sl.registerSingleton<MyListStore>(_FakeMyListStore([mangaItem]));
        sl.registerSingleton<ContentModeCubit>(
          _FakeContentModeCubit(ContentMode.anime),
        );

        await tester.pumpWidget(authed(const MyListScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Nothing here in this filter'), findsOneWidget);
      },
    );

    testWidgets(
      'manga mode, list has only an anime item (filtered to nothing) — '
      'reading-specific filtered wording',
      (tester) async {
        const animeItem = MediaItem(
          id: 'a1',
          title: 'Anime Show',
          url: '/a1',
          type: ProviderType.anime,
          sourceId: 's',
        );
        sl.registerSingleton<MyListStore>(_FakeMyListStore([animeItem]));
        sl.registerSingleton<ContentModeCubit>(
          _FakeContentModeCubit(ContentMode.manga),
        );

        await tester.pumpWidget(authed(const MyListScreen()));
        await tester.pumpAndSettle();

        expect(find.text('No manga here in this filter'), findsOneWidget);
      },
    );
  });

  // ── readerFor (final whole-branch review, Finding 2) ──────────────────────
  // _resumeReading used to route every Continue Reading tap straight to
  // NovelReaderScreen, regardless of the entry's actual type — a leftover
  // from before MangaReaderScreen existed. readerFor is the extracted
  // decision the fix routes through; plain object construction, no pump
  // needed (and HomeScreen itself can't be pumped here — see the file
  // header comment).

  group('readerFor routing', () {
    const chapter = Episode(id: 'c1', title: 'Chapter 1', url: '/c1', number: 1);

    ReadEntry entryOf(ProviderType type) => ReadEntry(
      sourceId: 'src',
      showId: 'show',
      title: 'Title',
      chapterId: 'c1',
      chapterNumber: 1,
      chapterUrl: '/c1',
      pos: 1,
      total: 20,
      updatedMs: 1,
      type: type,
    );

    test('a manga ReadEntry routes to MangaReaderScreen', () {
      expect(readerFor(entryOf(ProviderType.manga), chapter),
          isA<MangaReaderScreen>());
    });

    test('a novel ReadEntry routes to NovelReaderScreen', () {
      expect(readerFor(entryOf(ProviderType.novel), chapter),
          isA<NovelReaderScreen>());
    });
  });
}
