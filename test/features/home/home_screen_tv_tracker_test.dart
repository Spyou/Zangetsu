import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_row.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:watch_app/features/home/home_screen_tv.dart';

// TV mirrors the phone's saved arrangement: the tracker rows the merge emits
// render as rails with the same chrome as the local ones — landscape progress
// cards for continue/new-episodes, the poster rail for status buckets. The
// merge itself is covered by home_cubit_rows_test; this pumps the screen
// against an already-merged state, like home_screen_tv_test does.

class _StubSourceRepository implements SourceRepository {
  const _StubSourceRepository();

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String get sourceId => 'test';
}

class _FakeAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _FakeAuthCubit() : super(const AuthState());
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets('the tracker rows of the arrangement render as rails', (
    tester,
  ) async {
    final entry = TrackerListItem(
      item: const MediaItem(
        id: '1',
        title: 'One Piece',
        url: '',
        type: ProviderType.anime,
        sourceId: '',
        malId: 1,
      ),
      status: WatchStatus.watching,
      progress: 4,
      totalEpisodes: 12,
    );
    final cubit = HomeCubit(const _StubSourceRepository());
    cubit.emit(
      HomeState(
        sections: [
          HomeSection(
            title: 'Trending',
            items: [
              const MediaItem(
                id: '2',
                title: 'Hero Show',
                url: '',
                type: ProviderType.anime,
                sourceId: '',
              ),
            ],
          ),
        ],
        rows: [
          const LocalContinueHomeRow(), // signed out: renders nothing
          TrackerContinueHomeRow(items: [entry], trackerName: 'AniList'),
          NewEpisodesHomeRow(items: [entry], trackerName: 'AniList'),
          TrackerListHomeRow(
            status: WatchStatus.watching,
            items: [entry],
            trackerName: 'AniList',
          ),
        ],
      ),
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<HomeCubit>.value(value: cubit),
          BlocProvider<AuthCubit>.value(value: _FakeAuthCubit()),
        ],
        child: const MaterialApp(home: HomeScreenTv()),
      ),
    );
    await tester.pumpAndSettle();

    // Rails below the hero are lazy slivers — scroll each into view before
    // it exists in the tree.
    final scrollable = find.byType(Scrollable).first;

    // First tracker rail: continue, with the "where you are" badge.
    expect(find.text('Continue on AniList'), findsOneWidget);
    expect(find.text('EP 4/12'), findsOneWidget);

    // New episodes rail: the "what's waiting" badge is one past the progress.
    await tester.scrollUntilVisible(
      find.text('New Episodes'),
      300,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('New Episodes'), findsOneWidget);
    expect(find.text('EP 5'), findsOneWidget);

    // The status bucket renders as the standard poster rail.
    await tester.scrollUntilVisible(
      find.text('Watching'),
      300,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('Watching'), findsOneWidget);

    // The local continue row (signed out, no history) renders nothing at all.
    expect(find.text('Continue Watching'), findsNothing);
  });
}
