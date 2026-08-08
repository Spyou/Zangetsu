import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';

/// Minimal [SourceRepository] stub — only [loadedSources] is used by
/// [ContentModeCubit], the rest just isn't called from these tests.
class _FakeSourceRepository implements SourceRepository {
  _FakeSourceRepository(List<String> ids)
      : loadedSources = [for (final id in ids) (id: id, name: id)];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  final List<({String id, String name})> loadedSources;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mode_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
    if (sl.isRegistered<SourceRepository>()) sl.unregister<SourceRepository>();
  });

  test('defaults to anime and persists mode', () async {
    await ActiveSourceCubit.init();
    final active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
    final cubit = await ContentModeCubit.create(active);
    expect(cubit.state, ContentMode.anime);

    await cubit.setMode(ContentMode.manga);
    expect(cubit.state, ContentMode.manga);

    final reloaded = await ContentModeCubit.create(active);
    expect(reloaded.state, ContentMode.manga);
  });

  // Also pins the C.3 ordering trap: the outgoing source must be captured
  // BEFORE the incoming mode's source is restored, or a switch parks the
  // newly-restored source under the outgoing mode's key instead of what was
  // really active there. A plain anime->manga->anime check wouldn't surface
  // this on its own (the corruption lands in the mode you just left, not the
  // one you land on) — the giveaway only shows up on the *next* switch back,
  // which is why this test goes one hop further than a bare round trip.
  test('remembers a separate active source per mode', () async {
    await ActiveSourceCubit.init();
    final active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
    final cubit = await ContentModeCubit.create(active);

    active.setSource('js:animesrc');
    await cubit.setMode(ContentMode.manga); // stores js:animesrc under src.anime
    active.setSource('js:mangasrc');
    await cubit.setMode(ContentMode.anime); // stores js:mangasrc under src.manga
    expect(active.state, 'js:animesrc'); // anime source restored

    await cubit.setMode(ContentMode.manga);
    expect(active.state, 'js:mangasrc'); // manga source restored
  });

  // ── B: stale remembered source ─────────────────────────────────────────
  test('does not restore a remembered source that no longer exists', () async {
    await ActiveSourceCubit.init();
    final active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
    final cubit = await ContentModeCubit.create(active);

    active.setSource('js:animesrc');
    await cubit.setMode(ContentMode.manga);
    active.setSource('js:stale_manga_src');
    await cubit.setMode(ContentMode.anime); // parks js:stale_manga_src under src.manga

    // The manga source was uninstalled since it was parked.
    sl.registerSingleton<SourceRepository>(
      _FakeSourceRepository(['js:animesrc']),
    );

    await cubit.setMode(ContentMode.manga);
    // Left alone rather than pointed at a source that no longer loads.
    expect(active.state, 'js:animesrc');
  });

  test('a remembered source that still exists IS restored', () async {
    await ActiveSourceCubit.init();
    final active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
    final cubit = await ContentModeCubit.create(active);

    active.setSource('js:animesrc');
    await cubit.setMode(ContentMode.manga);
    active.setSource('js:mangasrc');
    await cubit.setMode(ContentMode.anime); // parks js:mangasrc under src.manga

    sl.registerSingleton<SourceRepository>(
      _FakeSourceRepository(['js:animesrc', 'js:mangasrc']),
    );

    await cubit.setMode(ContentMode.manga);
    expect(active.state, 'js:mangasrc');
  });
}
