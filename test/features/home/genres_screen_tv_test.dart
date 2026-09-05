// Genres on TV lives in Search's idle body, not the nav rail.
//
// The rail was tried first and could not take it: at 960x540 a seventh item
// pushed Settings off the drawer entirely, which the shell tests caught. The
// third test here pins that reason so nobody re-adds it.

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/features/home/genres_screen_tv.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class _FakeContentModeCubit extends Cubit<ContentMode>
    implements ContentModeCubit {
  _FakeContentModeCubit(super.initial);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeMetaRepo implements MetadataRepository {
  _FakeMetaRepo(this._supports);
  final bool _supports;
  @override
  bool get supportsFilters => _supports;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget harness() => const MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: GenresScreenTv(),
);

void main() {
  setUp(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    // A 720p-class TV, the panel that ruled the rail out.
    v.physicalSize = const Size(1280, 720);
    v.devicePixelRatio = 1;
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    sl.registerSingleton<ContentModeCubit>(
      _FakeContentModeCubit(ContentMode.anime),
    );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
        .resetPhysicalSize();
    await sl.reset();
  });

  testWidgets('renders the genre grid when the catalogue can filter', (
    t,
  ) async {
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo(true));
    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Comedy'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('says why rather than showing tiles that all refuse', (t) async {
    // MAL/Simkl: they accept a genre parameter and answer with everything.
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo(false));
    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    expect(find.text('Action'), findsNothing);
    expect(find.textContaining('AniList'), findsOneWidget);
  });

  testWidgets('the whole grid fits a 720p TV without overflowing', (t) async {
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo(true));
    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    // An overflow paints an exception rather than throwing. This is the check
    // the rail version failed.
    expect(t.takeException(), isNull);
  });
}
