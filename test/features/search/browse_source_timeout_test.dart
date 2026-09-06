// A source that never answers used to leave the browse screen spinning for
// good: no error, no retry, nothing to tell a slow site from a dead one. The
// worst case was a Cloudflare host whose challenge solve never came back, which
// held the fetch open with nothing on screen to act on.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/search/cubit/browse_source_cubit.dart';

/// Never completes, like a provider stuck on a challenge.
class _HangingRepo implements CatalogueRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) =>
      Completer<List<HomeSection>>().future;

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) => Completer<List<MediaItem>>().future;
}

void main() {
  BrowseSourceCubit cubit() => BrowseSourceCubit(
    repo: _HangingRepo(),
    sourceId: 'cs:Stuck',
    timeout: const Duration(milliseconds: 60),
  );

  test('a source that never answers ends up failed, not spinning', () async {
    final c = cubit();
    await c.load();

    expect(c.state.loading, isFalse);
    expect(c.state.failed, isTrue);
    await c.close();
  });

  test('a search that never answers ends the same way', () async {
    final c = cubit();
    await c.search('anything');

    expect(c.state.searching, isFalse);
    expect(c.state.searchFailed, isTrue);
    await c.close();
  });

  test('the default ceiling is generous enough for a challenge solve', () async {
    // A first visit to a Cloudflare host pays for the solve before the real
    // request starts, so this cannot be tight — it only has to be finite.
    final c = BrowseSourceCubit(repo: _HangingRepo(), sourceId: 'x');
    expect(c.timeout.inSeconds, greaterThanOrEqualTo(35));
    await c.close();
  });
}
