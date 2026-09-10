import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_module.dart';

import '../../support/picker_deps.dart';

/// Pool order deliberately puts the ANIME source first, so a correct
/// affinity pass for movies/TV has to visibly move the other one up.
class _Repo implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'ani:42', name: 'HiAnime'),
    (id: 'moviebox', name: 'MovieBox'),
  ];
}

void main() {
  late Directory dir;
  final repo = _Repo();

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('kind_affinity');
    Hive.init(dir.path);
    await registerPickerDeps(aniyomi: [aniSource(id: 42, name: 'HiAnime')]);
    // An Aniyomi source buckets as anime; a bundled JS provider has no
    // declared type, so it lands in the movies catch-all — the two sides
    // this ordering is supposed to tell apart.
    await sl<ProviderRegistry>().installFromBundled(
      name: 'moviebox',
      jsSource: 'globalThis.x = 1;',
    );
  });

  tearDownAll(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  List<String> sweep(ZKind kind, {List<String> saved = const []}) =>
      sweepOrder(candidatesForKind(repo, kind), kind, saved)
          .map((s) => s.id)
          .toList();

  test('candidatesForKind only filters — it does not reorder', () {
    // Affinity moved to the sweep layer; this list also feeds the per-title
    // picker, which shows what is installed rather than a guess at relevance.
    expect(candidatesForKind(repo, ZKind.tv).map((s) => s.id), [
      'ani:42',
      'moviebox',
    ]);
  });

  test('anime sweeps anime sources first', () {
    expect(sweep(ZKind.anime).first, 'ani:42');
  });

  test('a TV series sweeps like a movie, not like anime', () {
    // ZKind.tv used to fall through to the anime bucket, so opening a
    // live-action series put anime sources at the front of both sweeps.
    expect(sweep(ZKind.movie).first, 'moviebox');
    expect(sweep(ZKind.tv).first, 'moviebox');
  });

  test('movie and TV sweep identically', () {
    expect(sweep(ZKind.tv), sweep(ZKind.movie));
  });

  test('a saved priority no longer overrules kind affinity', () {
    // The bug on device: affinity ran inside candidatesForKind and
    // applySourceOrder then rebuilt the list from the saved order, throwing
    // it away. An anime source ranked first was asked about every film.
    const saved = ['ani:42', 'moviebox'];
    expect(sweep(ZKind.tv, saved: saved).first, 'moviebox');
    expect(sweep(ZKind.anime, saved: saved).first, 'ani:42');
  });

  test('the saved order still decides WITHIN a group', () {
    // Only the two groups swap; the user's ranking inside each is untouched.
    expect(sweep(ZKind.anime, saved: ['moviebox', 'ani:42']), [
      'ani:42',
      'moviebox',
    ]);
    expect(sweep(ZKind.tv, saved: ['moviebox', 'ani:42']), [
      'moviebox',
      'ani:42',
    ]);
  });
}
