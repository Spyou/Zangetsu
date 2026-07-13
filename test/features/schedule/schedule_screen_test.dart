import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/schedule/airing_service.dart';
import 'package:watch_app/core/schedule/coming_soon_service.dart';
import 'package:watch_app/core/schedule/schedule_models.dart';
import 'package:watch_app/features/schedule/schedule_cubit.dart';
import 'package:watch_app/features/schedule/schedule_screen.dart';

// A cubit we can seed with a fixed state, so no services/sl needed.
class _StubCubit extends ScheduleCubit {
  _StubCubit(super.a, super.b, super.c, ScheduleState seed) { emit(seed); }
  @override
  Future<void> load() async {}
}

class _FA implements AiringService { @override noSuchMethod(Invocation i) => super.noSuchMethod(i); }
class _FS implements ComingSoonService { @override noSuchMethod(Invocation i) => super.noSuchMethod(i); }
class _FM implements MyListStore { @override noSuchMethod(Invocation i) => super.noSuchMethod(i); }

void main() {
  testWidgets('renders Anime timeline + Movies & TV segment', (tester) async {
    // Key the seed to today's local midnight so the selected day matches.
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final seed = ScheduleState(
      selectedDay: today,
      airingByDay: {
        today: [
          AiringEntry(malId: 1, title: 'My Anime', coverUrl: null, episode: 7,
              airsAtLocal: today.add(const Duration(hours: 18, minutes: 30)),
              format: 'TV'),
        ],
      },
      soonByDay: {
        today: [
          ComingSoonEntry(tmdbId: 5, isTv: false, title: 'Big Movie',
              posterUrl: null, releaseDate: today),
        ],
      },
      loadingAiring: false, loadingSoon: false,
    );
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<ScheduleCubit>(
        create: (_) => _StubCubit(_FA(), _FS(), _FM(), seed),
        child: const ScheduleBody(), // the phone view widget, cubit-driven
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('My Anime'), findsOneWidget);
    expect(find.textContaining('Episode 7'), findsOneWidget);
    // Switch to the Movies & TV segment.
    await tester.tap(find.text('Movies & TV'));
    await tester.pumpAndSettle();
    expect(find.text('Big Movie'), findsOneWidget);
  });
}
