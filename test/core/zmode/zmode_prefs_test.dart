import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zmode_prefs');
    Hive.init(dir.path);
    await ZModePrefs.init();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('is off by default and follows anime', () {
    expect(ZModePrefs.enabled, isFalse);
    expect(ZModePrefs.streamKind, StreamKind.anime);
  });

  test('persists the toggle and bumps revision', () async {
    final before = ZModePrefs.revision.value;
    await ZModePrefs.setEnabled(true);
    expect(ZModePrefs.enabled, isTrue);
    expect(ZModePrefs.revision.value, before + 1);
    await Hive.close();
    Hive.init(dir.path);
    await ZModePrefs.init();
    expect(ZModePrefs.enabled, isTrue);
  });

  test('persists streamKind', () async {
    await ZModePrefs.setStreamKind(StreamKind.movie);
    expect(ZModePrefs.streamKind, StreamKind.movie);
  });

  test('sourcesMode is off by default, round-trips and bumps revision', () async {
    expect(ZModePrefs.sourcesMode, isFalse);
    final before = ZModePrefs.revision.value;
    await ZModePrefs.setSourcesMode(true);
    expect(ZModePrefs.sourcesMode, isTrue);
    expect(ZModePrefs.revision.value, before + 1);
    await Hive.close();
    Hive.init(dir.path);
    await ZModePrefs.init();
    expect(ZModePrefs.sourcesMode, isTrue);
  });

  test('setting sourcesMode to the same value does not bump revision', () async {
    await ZModePrefs.setSourcesMode(true);
    final before = ZModePrefs.revision.value;
    await ZModePrefs.setSourcesMode(true);
    expect(ZModePrefs.revision.value, before);
  });

  test('reads as off before init without throwing', () async {
    await Hive.close();
    Hive.init(dir.path);
    expect(ZModePrefs.enabled, isFalse);
    expect(ZModePrefs.sourcesMode, isFalse);
  });

  // Sources is a second, independent dimension from ContentMode/StreamKind —
  // see the mode bar redesign. Picking a content mode must never touch
  // sourcesMode, and flipping sourcesMode must never touch ContentMode or
  // StreamKind, so every combination — including the one that used to be
  // unreachable — has to be reachable.
  group('independent of ContentMode/StreamKind', () {
    late ActiveSourceCubit active;
    late ContentModeCubit modeCubit;

    setUp(() async {
      await ActiveSourceCubit.init();
      active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
      modeCubit = await ContentModeCubit.create(active);
    });

    tearDown(() async {
      await modeCubit.close();
      await active.close();
    });

    test('Manga selected AND sourcesMode true — unreachable before this fix',
        () async {
      await modeCubit.setMode(ContentMode.manga);
      await ZModePrefs.setSourcesMode(true);

      expect(modeCubit.state, ContentMode.manga);
      expect(ZModePrefs.sourcesMode, isTrue);
    });

    test('picking a content mode leaves sourcesMode untouched', () async {
      await ZModePrefs.setSourcesMode(true);
      await modeCubit.setMode(ContentMode.novel);
      expect(ZModePrefs.sourcesMode, isTrue);
      await modeCubit.setMode(ContentMode.anime);
      expect(ZModePrefs.sourcesMode, isTrue);
    });

    test('toggling sourcesMode leaves ContentMode and StreamKind untouched',
        () async {
      await modeCubit.setMode(ContentMode.manga);
      await ZModePrefs.setStreamKind(StreamKind.movie);

      await ZModePrefs.setSourcesMode(true);
      expect(modeCubit.state, ContentMode.manga);
      expect(ZModePrefs.streamKind, StreamKind.movie);

      await ZModePrefs.setSourcesMode(false);
      expect(modeCubit.state, ContentMode.manga);
      expect(ZModePrefs.streamKind, StreamKind.movie);
    });
  });
}
