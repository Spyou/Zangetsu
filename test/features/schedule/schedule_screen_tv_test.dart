import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/schedule/airing_service.dart';
import 'package:watch_app/core/schedule/coming_soon_service.dart';
import 'package:watch_app/core/schedule/schedule_models.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/schedule/schedule_cubit.dart';
import 'package:watch_app/features/schedule/schedule_screen_tv.dart';

class _StubCubit extends ScheduleCubit {
  _StubCubit(super.a, super.b, super.c, ScheduleState seed) { emit(seed); }
  @override
  Future<void> load() async {}
}
class _FA implements AiringService { @override noSuchMethod(Invocation i) => super.noSuchMethod(i); }
class _FS implements ComingSoonService { @override noSuchMethod(Invocation i) => super.noSuchMethod(i); }
class _FMyList implements MyListStore { @override noSuchMethod(Invocation i) => super.noSuchMethod(i); }

void main() {
  testWidgets('TV schedule renders focusable airing cards', (tester) async {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final seed = ScheduleState(
      airingByDay: {
        today:
            [AiringEntry(malId: 1, title: 'TV Anime', coverUrl: null, episode: 3,
                airsAtLocal: today.add(const Duration(hours: 18)), format: 'TV')],
      },
      loadingAiring: false, loadingSoon: false,
    );
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<ScheduleCubit>(
        create: (_) => _StubCubit(_FA(), _FS(), _FMyList(), seed),
        child: const ScheduleScreenTv(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('TV Anime'), findsWidgets);
    expect(tester.widgetList<TvFocusable>(find.byType(TvFocusable)), isNotEmpty);
  });
}
